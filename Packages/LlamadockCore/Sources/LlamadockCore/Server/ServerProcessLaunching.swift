import Foundation

public enum ManagedProcessEvent: Equatable, Sendable {
    case output(
        source: LogSource,
        message: String,
        timestamp: Date
    )
    case terminated(status: Int32)
}

public protocol ManagedServerProcess: Sendable {
    var processIdentifier: Int32 { get async }
    func events() async -> AsyncStream<ManagedProcessEvent>
    func isRunning() async -> Bool
    func terminate() async
    func forceTerminate() async
}

public protocol ServerProcessLaunching: Sendable {
    func launch(
        _ invocation: ProcessInvocation
    ) async throws -> any ManagedServerProcess
}
