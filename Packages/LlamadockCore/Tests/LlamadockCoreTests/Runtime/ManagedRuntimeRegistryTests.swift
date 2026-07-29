import Foundation
import Testing
@testable import LlamadockCore

@Suite("Managed runtime registry")
struct ManagedRuntimeRegistryTests {
    @Test("persists registered runtimes and active previous pointers")
    func persistsAndRollsBack() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(
            path: "registry.json",
            directoryHint: .notDirectory
        )
        let firstRecord = makeRecord(
            build: 10_175,
            runtimesRoot: root
        )
        let secondRecord = makeRecord(
            build: 10_176,
            runtimesRoot: root
        )
        let registry = JSONManagedRuntimeRegistry(
            fileURL: fileURL,
            runtimesRoot: root
        )

        try await registry.register(firstRecord)
        try await registry.register(secondRecord)
        try await registry.activate(firstRecord.id)
        try await registry.activate(secondRecord.id)

        var snapshot = try await registry.snapshot()
        #expect(
            snapshot.installations
                == [firstRecord, secondRecord]
        )
        #expect(snapshot.activeRuntimeID == secondRecord.id)
        #expect(snapshot.previousRuntimeID == firstRecord.id)

        try await registry.rollback()
        snapshot = try await registry.snapshot()
        #expect(snapshot.activeRuntimeID == firstRecord.id)
        #expect(snapshot.previousRuntimeID == secondRecord.id)

        let restored = try await JSONManagedRuntimeRegistry(
            fileURL: fileURL,
            runtimesRoot: root
        )
        .snapshot()
        #expect(restored == snapshot)

        let rawJSON = try String(
            contentsOf: fileURL,
            encoding: .utf8
        )
        #expect(rawJSON.contains(#""schemaVersion" : 1"#))
        let siblingNames = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(siblingNames.isEmpty)
    }

    @Test("unknown activation leaves active unchanged")
    func failedActivationIsNonDestructive() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = JSONManagedRuntimeRegistry(
            fileURL: root.appending(path: "registry.json"),
            runtimesRoot: root
        )
        let record = makeRecord(
            build: 10_175,
            runtimesRoot: root
        )
        try await registry.register(record)
        try await registry.activate(record.id)
        let before = try await registry.snapshot()

        await #expect(
            throws: ManagedRuntimeRegistryError
                .runtimeNotFound("managed:b99999:macos-arm64")
        ) {
            try await registry.activate(
                "managed:b99999:macos-arm64"
            )
        }

        #expect(try await registry.snapshot() == before)
    }

    @Test("rejects records outside the app-owned runtime root")
    func rejectsExternalRecord() async {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = JSONManagedRuntimeRegistry(
            fileURL: root.appending(path: "registry.json"),
            runtimesRoot: root
        )
        let external = makeRecord(
            build: 10_175,
            runtimesRoot: URL(
                filePath: "/tmp/not-llamadock-owned",
                directoryHint: .isDirectory
            )
        )

        await #expect(
            throws: ManagedRuntimeRegistryError
                .pathOutsideRuntimeRoot(
                    external.installDirectory
                )
        ) {
            try await registry.register(external)
        }
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockRegistryTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    private func makeRecord(
        build: Int,
        runtimesRoot: URL
    ) -> ManagedRuntimeRecord {
        let tag = "b\(build)"
        let installDirectory = runtimesRoot.appending(
            path: "\(tag)-macos-arm64",
            directoryHint: .isDirectory
        )
        return ManagedRuntimeRecord(
            id: "managed:\(tag):macos-arm64",
            tag: tag,
            build: build,
            architecture: .arm64,
            installDirectory: installDirectory,
            llamaURL: installDirectory.appending(
                path: "llama",
                directoryHint: .notDirectory
            ),
            serverURL: installDirectory.appending(
                path: "llama-server",
                directoryHint: .notDirectory
            ),
            installedAt: Date(
                timeIntervalSince1970: TimeInterval(build)
            ),
            validatedAt: Date(
                timeIntervalSince1970: TimeInterval(build + 1)
            ),
            versionOutput: "version: \(build)",
            archiveSHA256: String(repeating: "a", count: 64)
        )
    }
}
