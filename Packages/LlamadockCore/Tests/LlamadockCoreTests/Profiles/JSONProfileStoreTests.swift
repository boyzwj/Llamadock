import Foundation
import Testing
@testable import LlamadockCore

@Suite("JSON profile store")
struct JSONProfileStoreTests {
    @Test("saves atomically and restores profiles in a new store instance")
    func persistsAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()

        let firstStore = JSONProfileStore(directory: directory)
        try await firstStore.save(profile)

        let expectedURL = directory.appending(
            path: "\(profile.id.uuidString).json",
            directoryHint: .notDirectory
        )
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(siblingNames == ["\(profile.id.uuidString).json"])

        let secondStore = JSONProfileStore(directory: directory)
        #expect(try await secondStore.load(id: profile.id) == profile)
        #expect(try await secondStore.loadAll() == [profile])
    }

    @Test("returns nil when the requested profile does not exist")
    func missingProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONProfileStore(directory: directory)

        #expect(try await store.load(id: UUID()) == nil)
    }
}
