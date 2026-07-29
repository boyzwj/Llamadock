import Foundation

public enum RuntimeSource: String, Codable, Sendable {
    case managed
    case officialInstaller
    case homebrew
    case custom
}

public struct RuntimeCandidate: Equatable, Hashable, Identifiable, Sendable {
    public let source: RuntimeSource
    public let llamaURL: URL?
    public let serverURL: URL?

    public init(
        source: RuntimeSource,
        llamaURL: URL?,
        serverURL: URL?
    ) {
        self.source = source
        self.llamaURL = llamaURL?.standardizedFileURL
        self.serverURL = serverURL?.standardizedFileURL
    }

    public var id: String {
        [
            source.rawValue,
            llamaURL?.path ?? "",
            serverURL?.path ?? "",
        ].joined(separator: ":")
    }
}
