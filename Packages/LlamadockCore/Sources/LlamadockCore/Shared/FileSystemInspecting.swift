import Foundation

public protocol FileSystemInspecting: Sendable {
    func isExecutableFile(at url: URL) -> Bool
}

public struct LocalFileSystemInspector: FileSystemInspecting {
    public init() {}

    public func isExecutableFile(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
