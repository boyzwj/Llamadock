import Foundation

/// The transparent, user-inspectable directory layout owned by LlamaDock.
public struct ApplicationDirectories: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var runtimes: URL {
        root.appending(path: "runtimes", directoryHint: .isDirectory)
    }

    public var runtimeDownloads: URL {
        runtimes.appending(path: "downloads", directoryHint: .isDirectory)
    }

    public var runtimeRegistry: URL {
        runtimes.appending(
            path: "registry.json",
            directoryHint: .notDirectory
        )
    }

    public var models: URL {
        root.appending(path: "models", directoryHint: .isDirectory)
    }

    public var profiles: URL {
        root.appending(path: "profiles", directoryHint: .isDirectory)
    }

    public var downloads: URL {
        root.appending(path: "downloads", directoryHint: .isDirectory)
    }

    public var logs: URL {
        root.appending(path: "logs", directoryHint: .isDirectory)
    }

    public var cache: URL {
        root.appending(path: "cache", directoryHint: .isDirectory)
    }

    public var githubCache: URL {
        cache.appending(path: "github", directoryHint: .isDirectory)
    }

    public var latestRuntimeReleaseCache: URL {
        githubCache.appending(
            path: "latest-runtime-release.json",
            directoryHint: .notDirectory
        )
    }

    public var settings: URL {
        root.appending(
            path: "settings.json",
            directoryHint: .notDirectory
        )
    }
}
