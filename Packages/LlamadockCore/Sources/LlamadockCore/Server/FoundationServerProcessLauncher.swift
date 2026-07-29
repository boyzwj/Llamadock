import Darwin
import Foundation

public struct FoundationServerProcessLauncher: ServerProcessLaunching {
    public init() {}

    public func launch(
        _ invocation: ProcessInvocation
    ) async throws -> any ManagedServerProcess {
        try FoundationManagedServerProcess(invocation: invocation)
    }
}

private final class FoundationManagedServerProcess:
    ManagedServerProcess,
    @unchecked Sendable
{
    private enum Channel {
        case standardOutput
        case standardError
    }

    private let process = Process()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let stream: AsyncStream<ManagedProcessEvent>
    private let continuation: AsyncStream<ManagedProcessEvent>.Continuation
    private let lock = NSLock()

    private var standardOutputFinished = false
    private var standardErrorFinished = false
    private var terminationStatus: Int32?
    private var streamFinished = false

    init(invocation: ProcessInvocation) throws {
        let pair = AsyncStream<ManagedProcessEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation

        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            self?.consume(handle, channel: .standardOutput)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            self?.consume(handle, channel: .standardError)
        }
        process.terminationHandler = { [weak self] process in
            self?.recordTermination(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            standardOutputPipe.fileHandleForReading.readabilityHandler = nil
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.finish()
            throw error
        }
    }

    var processIdentifier: Int32 {
        get async {
            process.processIdentifier
        }
    }

    func events() async -> AsyncStream<ManagedProcessEvent> {
        stream
    }

    func isRunning() async -> Bool {
        lock.withLock {
            process.isRunning
        }
    }

    func terminate() async {
        lock.withLock {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func forceTerminate() async {
        lock.withLock {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func consume(
        _ handle: FileHandle,
        channel: Channel
    ) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            recordChannelFinished(channel)
            return
        }

        continuation.yield(
            .output(
                source: channel == .standardOutput
                    ? .standardOutput
                    : .standardError,
                message: String(decoding: data, as: UTF8.self),
                timestamp: Date()
            )
        )
    }

    private func recordChannelFinished(_ channel: Channel) {
        lock.lock()
        switch channel {
        case .standardOutput:
            standardOutputFinished = true
        case .standardError:
            standardErrorFinished = true
        }
        let finalStatus = statusIfComplete()
        lock.unlock()
        finishIfNeeded(status: finalStatus)
    }

    private func recordTermination(status: Int32) {
        lock.lock()
        terminationStatus = status
        let finalStatus = statusIfComplete()
        lock.unlock()
        finishIfNeeded(status: finalStatus)
    }

    private func statusIfComplete() -> Int32? {
        guard
            !streamFinished,
            standardOutputFinished,
            standardErrorFinished,
            let terminationStatus
        else {
            return nil
        }
        streamFinished = true
        return terminationStatus
    }

    private func finishIfNeeded(status: Int32?) {
        guard let status else {
            return
        }

        process.terminationHandler = nil
        continuation.yield(.terminated(status: status))
        continuation.finish()
    }
}
