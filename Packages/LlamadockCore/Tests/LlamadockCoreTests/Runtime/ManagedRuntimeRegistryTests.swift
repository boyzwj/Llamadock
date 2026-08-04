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
            runtimesRoot: root,
            capabilities: RuntimeCapabilitiesParser().parse(
                "--model FNAME --host HOST --port PORT",
                detectedAt: Date(timeIntervalSince1970: 10_176)
            )
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

    @Test("rejects a managed record that points at a reserved owned child")
    func rejectsReservedOwnedChild() async {
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
        let dangerousDirectory = root.appending(
            path: "downloads",
            directoryHint: .isDirectory
        )
        let dangerous = ManagedRuntimeRecord(
            id: record.id,
            tag: record.tag,
            build: record.build,
            architecture: record.architecture,
            installDirectory: dangerousDirectory,
            llamaURL: dangerousDirectory.appending(path: "llama"),
            serverURL: dangerousDirectory.appending(
                path: "llama-server"
            ),
            installedAt: record.installedAt,
            validatedAt: record.validatedAt,
            versionOutput: record.versionOutput,
            archiveSHA256: record.archiveSHA256
        )

        await #expect(
            throws: ManagedRuntimeRegistryError.invalidRecord(
                id: dangerous.id,
                reason: "install directory name does not match the runtime"
            )
        ) {
            try await registry.register(dangerous)
        }
    }

    @Test("removes an unused managed runtime and its owned directory")
    func removesUnusedRuntime() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = JSONManagedRuntimeRegistry(
            fileURL: root.appending(path: "registry.json"),
            runtimesRoot: root
        )
        let active = makeRecord(
            build: 10_175,
            runtimesRoot: root
        )
        let previous = makeRecord(
            build: 10_176,
            runtimesRoot: root
        )
        let unused = makeRecord(
            build: 10_177,
            runtimesRoot: root
        )
        for record in [active, previous, unused] {
            try createRuntimeDirectory(for: record)
            try await registry.register(record)
        }
        try await registry.activate(previous.id)
        try await registry.activate(active.id)

        try await registry.remove(
            unused.id,
            protectedRuntimeIDs: []
        )

        let snapshot = try await registry.snapshot()
        #expect(snapshot.installations == [active, previous])
        #expect(snapshot.activeRuntimeID == active.id)
        #expect(snapshot.previousRuntimeID == previous.id)
        #expect(
            !FileManager.default.fileExists(
                atPath: unused.installDirectory.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: active.installDirectory.path
            )
        )
    }

    @Test("refuses to remove active, previous, or in-use runtimes")
    func refusesProtectedRuntimeRemoval() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = JSONManagedRuntimeRegistry(
            fileURL: root.appending(path: "registry.json"),
            runtimesRoot: root
        )
        let active = makeRecord(
            build: 10_175,
            runtimesRoot: root
        )
        let previous = makeRecord(
            build: 10_176,
            runtimesRoot: root
        )
        let inUse = makeRecord(
            build: 10_177,
            runtimesRoot: root
        )
        for record in [active, previous, inUse] {
            try createRuntimeDirectory(for: record)
            try await registry.register(record)
        }
        try await registry.activate(previous.id)
        try await registry.activate(active.id)
        let before = try await registry.snapshot()

        await #expect(
            throws: ManagedRuntimeRegistryError
                .activeRuntimeCannotBeRemoved(active.id)
        ) {
            try await registry.remove(
                active.id,
                protectedRuntimeIDs: []
            )
        }
        await #expect(
            throws: ManagedRuntimeRegistryError
                .previousRuntimeCannotBeRemoved(previous.id)
        ) {
            try await registry.remove(
                previous.id,
                protectedRuntimeIDs: []
            )
        }
        await #expect(
            throws: ManagedRuntimeRegistryError
                .runtimeInUse(inUse.id)
        ) {
            try await registry.remove(
                inUse.id,
                protectedRuntimeIDs: [inUse.id]
            )
        }

        #expect(try await registry.snapshot() == before)
        for record in [active, previous, inUse] {
            #expect(
                FileManager.default.fileExists(
                    atPath: record.installDirectory.path
                )
            )
        }
    }

    @Test("unknown removal leaves the registry unchanged")
    func unknownRemovalIsNonDestructive() async throws {
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
        try createRuntimeDirectory(for: record)
        try await registry.register(record)
        let before = try await registry.snapshot()
        let missingID = "managed:b99999:macos-arm64"

        await #expect(
            throws: ManagedRuntimeRegistryError
                .runtimeNotFound(missingID)
        ) {
            try await registry.remove(
                missingID,
                protectedRuntimeIDs: []
            )
        }

        #expect(try await registry.snapshot() == before)
        #expect(
            FileManager.default.fileExists(
                atPath: record.installDirectory.path
            )
        )
    }

    @Test("removes a stale registry entry whose owned directory is gone")
    func removesMissingOwnedDirectoryRecord() async throws {
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

        try await registry.remove(
            record.id,
            protectedRuntimeIDs: []
        )

        #expect(
            try await registry.snapshot().installations.isEmpty
        )
    }

    private func createRuntimeDirectory(
        for record: ManagedRuntimeRecord
    ) throws {
        try FileManager.default.createDirectory(
            at: record.installDirectory,
            withIntermediateDirectories: true
        )
        try Data("runtime".utf8).write(
            to: record.serverURL
        )
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
        runtimesRoot: URL,
        capabilities: RuntimeCapabilities? = nil
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
            archiveSHA256: String(repeating: "a", count: 64),
            capabilities: capabilities
        )
    }
}
