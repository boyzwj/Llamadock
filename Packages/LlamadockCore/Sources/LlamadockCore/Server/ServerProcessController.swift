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
    case endpointUnavailable(
        host: String,
        port: UInt16,
        reason: String
    )
    case launchFailed(reason: String)
}

extension ServerProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A LlamaDock-owned server is already active."
        case .invalidEndpoint(let host, let port):
            "The server endpoint \(host):\(port) is invalid."
        case .endpointUnavailable(_, _, let reason):
            reason
        case .launchFailed(let reason):
            "llama-server could not be launched: \(reason)"
        }
    }
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
    public let metrics: ServerProcessMetrics?

    public init(
        state: ServerState,
        run: ServerRun?,
        logs: [LogEvent],
        metrics: ServerProcessMetrics? = nil
    ) {
        self.state = state
        self.run = run
        self.logs = logs
        self.metrics = metrics
    }
}

public actor ServerProcessController {
    private let launcher: any ServerProcessLaunching
    private let healthChecker: any ServerHealthChecking
    private let endpointChecker: any ServerEndpointChecking
    private let metricsReader: any ProcessMetricsReading
    private let ownershipStore: (any ServerOwnershipStoring)?
    private let processInspector: any ServerProcessInspecting
    private var state: ServerState = .stopped
    private var run: ServerRun?
    private var ownedProcess: (any ManagedServerProcess)?
    private var eventTask: Task<Void, Never>?
    private var logBuffer: BoundedLogBuffer

    public init(
        launcher: any ServerProcessLaunching = FoundationServerProcessLauncher(),
        healthChecker: any ServerHealthChecking = LlamaServerHealthAdapter(),
        endpointChecker: any ServerEndpointChecking = SocketServerEndpointChecker(),
        metricsReader: any ProcessMetricsReading =
            ProcessMetricsReader(),
        logBuffer: BoundedLogBuffer = BoundedLogBuffer(),
        ownershipStore: (any ServerOwnershipStoring)? = nil,
        processInspector: any ServerProcessInspecting =
            DarwinServerProcessInspector()
    ) {
        self.launcher = launcher
        self.healthChecker = healthChecker
        self.endpointChecker = endpointChecker
        self.metricsReader = metricsReader
        self.logBuffer = logBuffer
        self.ownershipStore = ownershipStore
        self.processInspector = processInspector
    }

    public func snapshot() -> ServerSnapshot {
        ServerSnapshot(
            state: state,
            run: run,
            logs: logBuffer.events,
            metrics: run.flatMap { currentRun in
                guard ownedProcess != nil else {
                    return nil
                }
                return metricsReader.sample(
                    processIdentifier:
                        currentRun.processIdentifier,
                    now: Date()
                )
            }
        )
    }

    public func clearLogs() {
        logBuffer.removeAll()
    }

    public func recoverOrphanedServer(
        gracePeriod: Duration = .seconds(2)
    ) async -> ServerOwnershipRecoveryResult {
        guard ownedProcess == nil, let ownershipStore else {
            return .noRecord
        }

        let record: ServerOwnershipRecord
        do {
            guard let stored = try await ownershipStore.load() else {
                return .noRecord
            }
            record = stored
        } catch {
            return .failed(reason: error.localizedDescription)
        }

        guard
            let identity = processInspector.identity(
                processIdentifier: record.processIdentifier
            ),
            identityMatchesRecord(identity, record: record)
        else {
            do {
                try await ownershipStore.remove()
                return .staleRecordRemoved
            } catch {
                return .failed(reason: error.localizedDescription)
            }
        }

        guard identity.parentProcessIdentifier == 1 else {
            return .failed(
                reason: "The recorded llama-server is still owned by process "
                    + "\(identity.parentProcessIdentifier)."
            )
        }

        processInspector.terminate(
            processIdentifier: record.processIdentifier
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        while
            processStillMatches(record),
            clock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if processStillMatches(record) {
            processInspector.forceTerminate(
                processIdentifier: record.processIdentifier
            )
            let forceDeadline = clock.now.advanced(by: .seconds(1))
            while
                processStillMatches(record),
                clock.now < forceDeadline
            {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        guard !processStillMatches(record) else {
            return .failed(
                reason: "Could not terminate the orphaned llama-server "
                    + "process \(record.processIdentifier)."
            )
        }

        do {
            try await ownershipStore.remove()
            return .orphanTerminated(
                processIdentifier: record.processIdentifier
            )
        } catch {
            return .failed(reason: error.localizedDescription)
        }
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
        if case .unavailable(let reason) = endpointChecker.check(
            host: host,
            port: port
        ) {
            state = .failed(reason: reason)
            throw ServerProcessError.endpointUnavailable(
                host: host,
                port: port,
                reason: reason
            )
        }

        eventTask?.cancel()
        eventTask = nil
        metricsReader.reset()
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
        let processIdentifier = await process.processIdentifier
        let processStartTime = processInspector.identity(
            processIdentifier: processIdentifier
        )?.processStartTime ?? Date()
        let currentRun = ServerRun(
            processIdentifier: processIdentifier,
            processStartTime: processStartTime,
            runtimeID: runtimeID,
            profileID: profileID,
            command: invocation,
            baseURL: baseURL
        )
        if let ownershipStore {
            do {
                try await ownershipStore.save(
                    ServerOwnershipRecord(
                        ownerProcessIdentifier: Int32(
                            ProcessInfo.processInfo.processIdentifier
                        ),
                        processIdentifier: processIdentifier,
                        processStartTime: processStartTime,
                        executableURL: invocation.executableURL,
                        runtimeID: runtimeID,
                        profileID: profileID,
                        host: host,
                        port: port
                    )
                )
            } catch {
                await process.terminate()
                if await process.isRunning() {
                    await process.forceTerminate()
                }
                ownedProcess = nil
                metricsReader.reset()
                let reason = "Could not persist server ownership: "
                    + error.localizedDescription
                state = .failed(reason: reason)
                throw ServerProcessError.launchFailed(reason: reason)
            }
        }
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
            metricsReader.reset()
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
        metricsReader.reset()
        state = .stopped
        await removeOwnershipRecord()
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
                metricsReader.reset()
                eventTask?.cancel()
                eventTask = nil
                await removeOwnershipRecord()
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
        metricsReader.reset()
        eventTask?.cancel()
        eventTask = nil
        await removeOwnershipRecord()
    }

    private func receive(
        _ event: ManagedProcessEvent,
        runID: UUID
    ) async {
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
            metricsReader.reset()
            await removeOwnershipRecord()
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

    private func identityMatchesRecord(
        _ identity: ServerProcessIdentity,
        record: ServerOwnershipRecord
    ) -> Bool {
        identity.processIdentifier == record.processIdentifier
            && identity.executableURL.resolvingSymlinksInPath()
                == record.executableURL.resolvingSymlinksInPath()
            && abs(
                identity.processStartTime.timeIntervalSince(
                    record.processStartTime
                )
            ) < 2
    }

    private func processStillMatches(
        _ record: ServerOwnershipRecord
    ) -> Bool {
        guard let identity = processInspector.identity(
            processIdentifier: record.processIdentifier
        ) else {
            return false
        }
        return identityMatchesRecord(identity, record: record)
    }

    private func removeOwnershipRecord() async {
        try? await ownershipStore?.remove()
    }

    private func makeBaseURL(host: String, port: UInt16) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        return components.url
    }
}
