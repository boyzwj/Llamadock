import Foundation

public struct RuntimeInstallation: Equatable, Identifiable, Sendable {
    public var id: String
    public var source: RuntimeSource
    public var llamaURL: URL?
    public var serverURL: URL
    public var versionOutput: String
    public var capabilities: RuntimeCapabilities

    public init(
        id: String,
        source: RuntimeSource,
        llamaURL: URL?,
        serverURL: URL,
        versionOutput: String,
        capabilities: RuntimeCapabilities
    ) {
        self.id = id
        self.source = source
        self.llamaURL = llamaURL?.standardizedFileURL
        self.serverURL = serverURL.standardizedFileURL
        self.versionOutput = versionOutput
        self.capabilities = capabilities
    }
}
