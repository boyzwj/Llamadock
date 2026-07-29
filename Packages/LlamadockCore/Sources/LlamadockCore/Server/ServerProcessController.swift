import Foundation

public enum ServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case degraded(reason: String)
    case failed(reason: String)
    case stopping
}

public enum ServerProcessError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidEndpoint(host: String, port: UInt16)
    case launchFailed(reason: String)
}

public struct ServerRun: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let processIdentifier: Int32
    public let processStartTime: Date
    public let runtimeID: String
    public let profileID: UUID
    public let command: ProcessInvocation
    public let baseURL: URL

    public init(
        id: UUID = UUID(),
        processIdentifier: Int32,
        processStartTime: Date,
        runtimeID: String,
        profileID: UUID,
        command: ProcessInvocation,
        baseURL: URL
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.runtimeID = runtimeID
        self.profileID = profileID
        self.command = command
        self.baseURL = baseURL
    }
}

public struct ServerSnapshot: Equatable, Sendable {
    public let state: ServerState
    public let run: ServerRun?
    public let logs: [LogEvent]

    public init(
        state: ServerState,
        run: ServerRun?,
        logs: [LogEvent]
    ) {
        self.state = state
        self.run = run
        self.logs = logs
    }
}

public actor ServerProcessController {
    private let launcher: any ServerProcessLaunching
    private let healthChecker: any ServerHealthChecking
    private var state: ServerState = .stopped
    private var run: ServerRun?
    private var ownedProcess: (any ManagedServerProcess)?
    private var eventTask: Task<Void, Never>?
    private var logBuffer: BoundedLogBuffer

    public init(
        launcher: any ServerProcessLaunching = FoundationServerProcessLauncher(),
        healthChecker: any ServerHealthChecking = LlamaServerHealthAdapter(),
        logBuffer: BoundedLogBuffer = BoundedLogBuffer()
    ) {
        self.launcher = launcher
        self.healthChecker = healthChecker
        self.logBuffer = logBuffer
    }

    public func snapshot() -> ServerSnapshot {
        ServerSnapshot(
            state: state,
            run: run,
            logs: logBuffer.events
        )
    }

    public func start(
        profileID: UUID,
        runtimeID: String,
        invocation: ProcessInvocation,
        host: String,
        port: UInt16,
        readinessTimeout: Duration = .seconds(120)
    ) async throws {
        guard ownedProcess == nil else {
            throw ServerProcessError.alreadyRunning
        }
        switch state {
        case .stopped, .failed:
            break
        case .starting, .ready, .degraded, .stopping:
            throw ServerProcessError.alreadyRunning
        }
        guard let baseURL = makeBaseURL(host: host, port: port) else {
            throw ServerProcessError.invalidEndpoint(
                host: host,
                port: port
            )
        }

        eventTask?.cancel()
        eventTask = nil
        run = nil
        state = .starting
        logBuffer.removeAll()

        let process: any ManagedServerProcess
        do {
            process = try await launcher.launch(invocation)
        } catch {
            let reason = error.localizedDescription
            state = .failed(reason: reason)
            throw ServerProcessError.launchFailed(reason: reason)
        }

        ownedProcess = process
        let currentRun = ServerRun(
            processIdentifier: await process.processIdentifier,
            processStartTime: Date(),
            runtimeID: runtimeID,
            profileID: profileID,
            command: invocation,
            baseURL: baseURL
        )
        run = currentRun
        let stream = await process.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                await self?.receive(
                    event,
                    runID: currentRun.id
                )
            }
        }

        await waitForReadiness(
            process: process,
            baseURL: baseURL,
            runID: currentRun.id,
            timeout: readinessTimeout
        )
    }

    public func stop(
        gracePeriod: Duration = .seconds(5)
    ) async {
        guard let process = ownedProcess else {
            state = .stopped
            run = nil
            return
        }

        state = .stopping
        await process.terminate()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        while await process.isRunning(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if await process.isRunning() {
            await process.forceTerminate()
        }

        ownedProcess = nil
        eventTask?.cancel()
        eventTask = nil
        run = nil
        state = .stopped
    }

    private func waitForReadiness(
        process: any ManagedServerProcess,
        baseURL: URL,
        runID: UUID,
        timeout: Duration
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let delays: [Duration] = [
            .milliseconds(200),
            .milliseconds(400),
            .milliseconds(800),
            .seconds(1),
            .seconds(2),
        ]
        var delayIndex = 0

        while clock.now <= deadline {
            guard isCurrentRun(runID) else {
                return
            }
            guard await process.isRunning() else {
                guard isCurrentRun(runID) else {
                    return
                }
                state = .failed(
                    reason: "Process exited before readiness."
                )
                ownedProcess = nil
                eventTask?.cancel()
                eventTask = nil
                return
            }

            let health = await healthChecker.check(baseURL: baseURL)
            guard isCurrentRun(runID) else {
                return
            }
            switch health {
            case .ready:
                state = .ready
                return
            case .degraded(let reason):
                state = .degraded(reason: reason)
                return
            case .starting, .unavailable:
                break
            }

            let delay = delays[min(delayIndex, delays.count - 1)]
            delayIndex += 1
            try? await Task.sleep(for: delay)
        }

        guard isCurrentRun(runID) else {
            return
        }
        state = .failed(
            reason: "Readiness timed out."
        )
        await process.forceTerminate()
        ownedProcess = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func receive(
        _ event: ManagedProcessEvent,
        runID: UUID
    ) {
        guard run?.id == runID else {
            return
        }
        switch event {
        case .output(let source, let message, let timestamp):
            logBuffer.append(
                LogEvent(
                    timestamp: timestamp,
                    source: source,
                    message: message
                )
            )
        case .terminated(let status):
            ownedProcess = nil
            switch state {
            case .stopping:
                state = .stopped
            case .failed, .stopped:
                break
            case .starting, .ready, .degraded:
                state = .failed(
                    reason: "Process exited with code \(status)."
                )
            }
        }
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        guard run?.id == runID, ownedProcess != nil else {
            return false
        }
        switch state {
        case .stopped, .stopping:
            return false
        case .starting, .ready, .degraded, .failed:
            return true
        }
    }

    private func makeBaseURL(host: String, port: UInt16) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        return components.url
    }
}
