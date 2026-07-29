import Darwin
import Foundation

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

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

        let standardOutputTask = Task.detached(priority: .utility) {
            standardOutputHandle.handle.readDataToEndOfFile()
        }
        let standardErrorTask = Task.detached(priority: .utility) {
            standardErrorHandle.handle.readDataToEndOfFile()
        }

        do {
            try ownedProcess.process.run()
        } catch {
            standardOutputPipe.fileHandleForWriting.closeFile()
            standardErrorPipe.fileHandleForWriting.closeFile()
            _ = await standardOutputTask.value
            _ = await standardErrorTask.value
            throw error
        }

        let race = await withTaskCancellationHandler {
            await withTaskGroup(of: ProcessRace.self) { group in
                group.addTask {
                    ownedProcess.process.waitUntilExit()
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

private final class OwnedProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()

    func forceTerminate() {
        lock.lock()
        defer { lock.unlock() }

        guard process.isRunning else {
            return
        }

        kill(process.processIdentifier, SIGKILL)
    }
}

private final class ReadHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}
