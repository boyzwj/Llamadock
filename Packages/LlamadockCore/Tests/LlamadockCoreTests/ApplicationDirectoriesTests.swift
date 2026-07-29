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
        #expect(directories.models == root.appending(path: "models", directoryHint: .isDirectory))
        #expect(directories.profiles == root.appending(path: "profiles", directoryHint: .isDirectory))
        #expect(directories.downloads == root.appending(path: "downloads", directoryHint: .isDirectory))
        #expect(directories.logs == root.appending(path: "logs", directoryHint: .isDirectory))
        #expect(directories.cache == root.appending(path: "cache", directoryHint: .isDirectory))
    }
}
