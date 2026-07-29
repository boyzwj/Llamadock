import Foundation

public enum ProcessInvocationError: Error, Equatable, Sendable {
    case executableMustBeAbsolute(URL)
}

/// A subprocess request that can be handed directly to Foundation `Process`.
///
/// Arguments remain individual tokens. This type deliberately has no shell
/// command-string initializer.
public struct ProcessInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw ProcessInvocationError.executableMustBeAbsolute(executableURL)
        }

        self.executableURL = executableURL.standardizedFileURL
        self.arguments = arguments
        self.environment = environment
    }

    public var displayCommand: String {
        ([executableURL.path] + arguments)
            .map(ShellDisplayQuoting.quote)
            .joined(separator: " ")
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(
        terminationStatus: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool = false
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        _ invocation: ProcessInvocation,
        timeout: Duration
    ) async throws -> ProcessResult
}

private enum ShellDisplayQuoting {
    private static let safeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "0123456789_@%+=:,./-"
    )

    static func quote(_ token: String) -> String {
        guard !token.isEmpty else {
            return "''"
        }

        if token.unicodeScalars.allSatisfy(safeCharacters.contains) {
            return token
        }

        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
