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
    private let declaredID: String?

    public init(
        source: RuntimeSource,
        llamaURL: URL?,
        serverURL: URL?,
        id: String? = nil
    ) {
        self.source = source
        self.llamaURL = llamaURL?.standardizedFileURL
        self.serverURL = serverURL?.standardizedFileURL
        self.declaredID = id
    }

    public var id: String {
        if let declaredID {
            return declaredID
        }
        return [
            source.rawValue,
            llamaURL?.path ?? "",
            serverURL?.path ?? "",
        ].joined(separator: ":")
    }
}
