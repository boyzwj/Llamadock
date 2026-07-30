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
            break
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
            throw FoundationProcessLaunchError(reason: reason)
        }

        let standardOutputTask = Task {
            await standardOutputHandle.readToEnd()
        }
        let standardErrorTask = Task {
            await standardErrorHandle.readToEnd()
        }

        let race = await withTaskCancellationHandler {
            await withTaskGroup(of: ProcessRace.self) { group in
                group.addTask {
                    await ownedProcess.waitUntilExit()
                    return .exited
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    } catch {
                        return .cancelled
                    }
                }

                let first = await group.next() ?? .cancelled
                if first != .exited {
                    ownedProcess.forceTerminate()
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            ownedProcess.forceTerminate()
        }

        let standardOutputData = await standardOutputTask.value
        let standardErrorData = await standardErrorTask.value

        if Task.isCancelled || race == .cancelled {
            throw CancellationError()
        }

        return ProcessResult(
            terminationStatus: ownedProcess.process.terminationStatus,
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
    private var terminationRequested = false

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

    func waitUntilExit() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.process.waitUntilExit()
                continuation.resume()
            }
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

private final class ReadHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.handle.readDataToEndOfFile()
                )
            }
        }
    }
}
