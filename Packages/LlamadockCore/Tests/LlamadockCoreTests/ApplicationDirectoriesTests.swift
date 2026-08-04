import Foundation
import Testing
@testable import LlamadockCore

@Suite("Application directories")
struct ApplicationDirectoriesTests {
    @Test("exposes the transparent on-disk layout")
    func exposesTransparentLayout() {
        let root = URL(filePath: "/tmp/Llamadock-tests", directoryHint: .isDirectory)
        let directories = ApplicationDirectories(root: root)

        #expect(directories.runtimes == root.appending(path: "runtimes", directoryHint: .isDirectory))
        #expect(directories.runtimeDownloads == root.appending(path: "runtimes/downloads", directoryHint: .isDirectory))
        #expect(directories.runtimeRegistry == root.appending(path: "runtimes/registry.json", directoryHint: .notDirectory))
        #expect(directories.models == root.appending(path: "models", directoryHint: .isDirectory))
        #expect(directories.profiles == root.appending(path: "profiles", directoryHint: .isDirectory))
        #expect(directories.modelsPreset == root.appending(path: "server/models.ini", directoryHint: .notDirectory))
        #expect(directories.serverOwnership == root.appending(path: "server/ownership.json", directoryHint: .notDirectory))
        #expect(directories.downloads == root.appending(path: "downloads", directoryHint: .isDirectory))
        #expect(directories.downloadState == root.appending(path: "downloads/state.json", directoryHint: .notDirectory))
        #expect(directories.downloadJobs == root.appending(path: "downloads/jobs", directoryHint: .isDirectory))
        #expect(directories.logs == root.appending(path: "logs", directoryHint: .isDirectory))
        #expect(directories.cache == root.appending(path: "cache", directoryHint: .isDirectory))
        #expect(
            directories.githubCache
                == root.appending(
                    path: "cache/github",
                    directoryHint: .isDirectory
                )
        )
        #expect(
            directories.latestRuntimeReleaseCache
                == root.appending(
                    path: "cache/github/latest-runtime-release.json",
                    directoryHint: .notDirectory
                )
        )
        #expect(
            directories.runtimeReleaseDetailsCache
                == root.appending(
                    path: "cache/github/runtime-releases",
                    directoryHint: .isDirectory
                )
        )
        #expect(
            directories.settings
                == root.appending(
                    path: "settings.json",
                    directoryHint: .notDirectory
                )
        )
    }
}
