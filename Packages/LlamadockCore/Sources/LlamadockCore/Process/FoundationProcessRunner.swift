import Darwin
import Foundation

public struct FoundationProcessRunner: ProcessRunning {
    private let launchQueue: DispatchQueue

    public init() {
        launchQueue = DispatchQueue.global(qos: .utility)
    }

    init(launchQueue: DispatchQueue) {
        self.launchQueue = launchQueue
    }

    public func run(
        _ invocation: ProcessInvocation,
        timeout: Duration
    ) async throws -> ProcessResult {
        let ownedProcess = OwnedProcess()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardOutputHandle = ReadHandle(
            standardOutputPipe.fileHandleForReading
        )
        let standardErrorHandle = ReadHandle(
            standardErrorPipe.fileHandleForReading
        )

        ownedProcess.process.executableURL = invocation.executableURL
        ownedProcess.process.arguments = invocation.arguments
        ownedProcess.process.environment = invocation.environment
        ownedProcess.process.standardOutput = standardOutputPipe
        ownedProcess.process.standardError = standardErrorPipe
        ownedProcess.installTerminationHandler()

        let launchOutcome = await withTaskCancellationHandler {
            await ownedProcess.launch(
                on: launchQueue,
                timeout: timeout
            )
        } onCancel: {
            ownedProcess.cancelLaunch()
        }

        switch launchOutcome {
        case .started:
            standardOutputPipe.fileHandleForWriting.closeFile()
            standardErrorPipe.fileHandleForWriting.closeFile()
        case .timedOut:
            return ProcessResult(
                terminationStatus: SIGKILL,
                standardOutput: "",
                standardError: "",
                timedOut: true
            )
        case .cancelled:
            throw CancellationError()
        case .failed(let reason):
            standardOutputPipe.fileHandleForWriting.closeFile()
            standardErrorPipe.fileHandleForWriting.closeFile()
            throw FoundationProcessLaunchError(reason: reason)
        }

        let standardOutputTask = Task {
            await standardOutputHandle.readToEnd()
        }
        let standardErrorTask = Task {
            await standardErrorHandle.readToEnd()
        }

        let race = await ownedProcess.waitForExit(
            timeout: timeout
        )
        if race != .exited {
            standardOutputHandle.close()
            standardErrorHandle.close()
        }

        let standardOutputData = await standardOutputTask.value
        let standardErrorData = await standardErrorTask.value

        if Task.isCancelled || race == .cancelled {
            throw CancellationError()
        }

        return ProcessResult(
            terminationStatus: race == .timedOut
                ? SIGKILL
                : ownedProcess.process.terminationStatus,
            standardOutput: String(
                decoding: standardOutputData,
                as: UTF8.self
            ),
            standardError: String(
                decoding: standardErrorData,
                as: UTF8.self
            ),
            timedOut: race == .timedOut
        )
    }
}

private enum ProcessRace: Sendable {
    case exited
    case timedOut
    case cancelled
}

private enum ProcessLaunchOutcome: Sendable {
    case started
    case timedOut
    case cancelled
    case failed(reason: String)
}

private struct FoundationProcessLaunchError:
    LocalizedError,
    Sendable
{
    let reason: String

    var errorDescription: String? {
        "Could not launch the process: \(reason)"
    }
}

private final class OwnedProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var launchRace: ProcessLaunchRace?
    private var terminationRace: ProcessTerminationRace?
    private var terminationRequested = false
    private var didTerminate = false

    func installTerminationHandler() {
        process.terminationHandler = { [weak self] _ in
            self?.recordTermination()
        }
    }

    func launch(
        on queue: DispatchQueue,
        timeout: Duration
    ) async -> ProcessLaunchOutcome {
        await withCheckedContinuation { continuation in
            let race = ProcessLaunchRace(continuation)
            lock.withLock {
                launchRace = race
            }

            queue.async {
                let outcome: ProcessLaunchOutcome
                do {
                    try self.process.run()
                    outcome = .started
                } catch {
                    outcome = .failed(
                        reason: error.localizedDescription
                    )
                }

                if self.shouldTerminateAfterLaunch {
                    self.forceTerminate()
                }
                race.resolve(outcome)
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                if race.resolve(.timedOut) {
                    self.forceTerminate()
                }
            }
        }
    }

    func waitForExit(
        timeout: Duration
    ) async -> ProcessRace {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let race = ProcessTerminationRace(continuation)
                let state = lock.withLock {
                    terminationRace = race
                    return (
                        didTerminate: didTerminate,
                        cancellationRequested:
                            terminationRequested
                    )
                }

                if state.didTerminate {
                    race.resolve(.exited)
                    return
                }
                if state.cancellationRequested {
                    race.resolve(.cancelled) {
                        self.forceTerminate()
                    }
                    return
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    race.resolve(.timedOut) {
                        self.forceTerminate()
                    }
                }
                race.installTimeoutTask(timeoutTask)
            }
        } onCancel: {
            cancelTerminationWait()
        }
    }

    func cancelLaunch() {
        let race = lock.withLock {
            launchRace
        }
        if race?.resolve(.cancelled) == true {
            forceTerminate()
        }
    }

    private func cancelTerminationWait() {
        let race = lock.withLock {
            terminationRequested = true
            return terminationRace
        }
        race?.resolve(.cancelled) {
            forceTerminate()
        }
    }

    private func recordTermination() {
        let race = lock.withLock {
            didTerminate = true
            return terminationRace
        }
        race?.resolve(.exited)
    }

    func forceTerminate() {
        let processIdentifier = lock.withLock {
            terminationRequested = true
            return process.isRunning
                ? process.processIdentifier
                : nil
        }

        if let processIdentifier {
            kill(processIdentifier, SIGKILL)
        }
    }

    private var shouldTerminateAfterLaunch: Bool {
        lock.withLock {
            terminationRequested
        }
    }
}

private final class ProcessLaunchRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<ProcessLaunchOutcome, Never>?

    init(
        _ continuation:
            CheckedContinuation<ProcessLaunchOutcome, Never>
    ) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(
        _ outcome: ProcessLaunchOutcome
    ) -> Bool {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        guard let continuation else {
            return false
        }
        continuation.resume(returning: outcome)
        return true
    }
}

private final class ProcessTerminationRace:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<ProcessRace, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        _ continuation:
            CheckedContinuation<ProcessRace, Never>
    ) {
        self.continuation = continuation
    }

    func installTimeoutTask(
        _ task: Task<Void, Never>
    ) {
        let shouldCancel = lock.withLock {
            guard continuation != nil else {
                return true
            }
            timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    func resolve(
        _ outcome: ProcessRace,
        beforeResume: () -> Void = {}
    ) -> Bool {
        let resolved = lock.withLock {
            let value = continuation
            continuation = nil
            let task = timeoutTask
            timeoutTask = nil
            return (value, task)
        }
        guard let continuation = resolved.0 else {
            return false
        }
        beforeResume()
        resolved.1?.cancel()
        continuation.resume(returning: outcome)
        return true
    }
}

private final class ReadHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning:
                        (try? self.handle.readToEnd()) ?? Data()
                )
            }
        }
    }

    func close() {
        try? handle.close()
    }
}
