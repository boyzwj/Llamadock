import Foundation
import Testing
@testable import LlamadockCore

@Suite("Server ownership store")
struct ServerOwnershipTests {
    @Test("reads the identity of a live Darwin process")
    func readsLiveProcessIdentity() {
        let processIdentifier = Int32(
            ProcessInfo.processInfo.processIdentifier
        )
        let identity = DarwinServerProcessInspector().identity(
            processIdentifier: processIdentifier
        )

        #expect(identity?.processIdentifier == processIdentifier)
        #expect(identity?.parentProcessIdentifier ?? 0 > 0)
        #expect(identity?.executableURL.path.isEmpty == false)
        #expect(identity?.processStartTime ?? .distantFuture < Date())
    }

    @Test("persists and removes the owned process identity")
    func persistsAndRemovesRecord() async throws {
        let root = URL(
            filePath: NSTemporaryDirectory(),
            directoryHint: .isDirectory
        ).appending(
            path: "llamadock-ownership-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(
            path: "server/ownership.json",
            directoryHint: .notDirectory
        )
        let store = JSONServerOwnershipStore(fileURL: fileURL)
        let record = ServerOwnershipRecord(
            ownerProcessIdentifier: 100,
            processIdentifier: 200,
            processStartTime: Date(timeIntervalSince1970: 1_785_315_100),
            executableURL: URL(filePath: "/runtime/llama-server"),
            runtimeID: "managed:b1234:macos-arm64",
            profileID: UUID(),
            host: "127.0.0.1",
            port: 8_080
        )

        try await store.save(record)

        #expect(try await store.load() == record)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try await store.remove()
        #expect(try await store.load() == nil)
    }

    @Test("rejects an unsupported schema")
    func rejectsUnsupportedSchema() async throws {
        let root = URL(
            filePath: NSTemporaryDirectory(),
            directoryHint: .isDirectory
        ).appending(
            path: "llamadock-ownership-schema-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONServerOwnershipStore(
            fileURL: root.appending(path: "ownership.json")
        )
        try await store.save(
            ServerOwnershipRecord(
                schemaVersion: 99,
                ownerProcessIdentifier: 100,
                processIdentifier: 200,
                processStartTime: .distantPast,
                executableURL: URL(filePath: "/runtime/llama-server"),
                runtimeID: "managed:test",
                profileID: UUID(),
                host: "127.0.0.1",
                port: 8_080
            )
        )

        await #expect(
            throws: ServerOwnershipStoreError
                .unsupportedSchemaVersion(99)
        ) {
            try await store.load()
        }
    }
}
