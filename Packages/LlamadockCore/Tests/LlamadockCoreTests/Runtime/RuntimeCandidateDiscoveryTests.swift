import Foundation
import Testing
@testable import LlamadockCore

@Suite("Runtime candidate discovery")
struct RuntimeCandidateDiscoveryTests {
    @Test("finds Homebrew llama and llama-server without PATH lookup")
    func findsHomebrewPair() {
        let llama = URL(filePath: "/opt/homebrew/bin/llama")
        let server = URL(filePath: "/opt/homebrew/bin/llama-server")
        let discovery = RuntimeCandidateDiscovery(
            fileSystem: FakeFileSystem(executables: [llama, server])
        )

        let candidates = discovery.discover()

        #expect(
            candidates
                == [
                    RuntimeCandidate(
                        source: .homebrew,
                        llamaURL: llama,
                        serverURL: server
                    )
                ]
        )
    }

    @Test("finds a user-selected custom server and its sibling llama binary")
    func findsCustomPair() {
        let directory = URL(
            filePath: "/Applications/llama-custom/bin",
            directoryHint: .isDirectory
        )
        let llama = directory.appending(path: "llama")
        let server = directory.appending(path: "custom-server")
        let discovery = RuntimeCandidateDiscovery(
            fileSystem: FakeFileSystem(executables: [llama, server])
        )

        let candidates = discovery.discover(customExecutableURLs: [server])

        #expect(
            candidates
                == [
                    RuntimeCandidate(
                        source: .custom,
                        llamaURL: llama,
                        serverURL: server
                    )
                ]
        )
    }

    @Test("does not duplicate a known Homebrew binary selected as custom")
    func deduplicatesKnownBinary() {
        let server = URL(filePath: "/opt/homebrew/bin/llama-server")
        let discovery = RuntimeCandidateDiscovery(
            fileSystem: FakeFileSystem(executables: [server])
        )

        let candidates = discovery.discover(customExecutableURLs: [server])

        #expect(candidates.count == 1)
        #expect(candidates.first?.source == .homebrew)
    }

    @Test("ignores missing or non-executable binaries")
    func ignoresMissingBinaries() {
        let discovery = RuntimeCandidateDiscovery(
            fileSystem: FakeFileSystem(executables: [])
        )

        #expect(discovery.discover().isEmpty)
    }

    @Test("discovers managed registry entries with stable IDs")
    func discoversManagedRuntime() {
        let installDirectory = URL(
            filePath: "/Library/Application Support/Llamadock/runtimes/b10176-macos-arm64",
            directoryHint: .isDirectory
        )
        let llama = installDirectory.appending(
            path: "llama-b10176/llama"
        )
        let server = installDirectory.appending(
            path: "llama-b10176/llama-server"
        )
        let record = ManagedRuntimeRecord(
            id: "managed:b10176:macos-arm64",
            tag: "b10176",
            build: 10_176,
            architecture: .arm64,
            installDirectory: installDirectory,
            llamaURL: llama,
            serverURL: server,
            installedAt: .distantPast,
            validatedAt: .distantPast,
            versionOutput: "version: 10176",
            archiveSHA256: String(repeating: "a", count: 64)
        )
        let discovery = RuntimeCandidateDiscovery(
            fileSystem: FakeFileSystem(
                executables: [llama, server]
            )
        )

        let candidates = discovery.discover(
            managedRuntimes: [record],
            customExecutableURLs: [server]
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.id == record.id)
        #expect(candidates.first?.source == .managed)
    }
}

private struct FakeFileSystem: FileSystemInspecting {
    let executables: Set<URL>

    func isExecutableFile(at url: URL) -> Bool {
        executables.contains(url)
    }
}
