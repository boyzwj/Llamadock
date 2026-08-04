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

    @Test("migrates v1 atomically and preserves unknown JSON fields")
    func migratesV1AndPreservesUnknownFields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var legacyProfile = makeProfile()
        legacyProfile.schemaVersion = 1
        legacyProfile.lastUsedAt = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var document = try #require(
            JSONSerialization.jsonObject(
                with: encoder.encode(legacyProfile)
            ) as? [String: Any]
        )
        document.removeValue(forKey: "router")
        document["pluginExtension"] = [
            "enabled": true,
        ]
        var server = try #require(
            document["server"] as? [String: Any]
        )
        server["futureRuntimeOption"] = "keep-me"
        document["server"] = server
        let profileURL = directory.appending(
            path: "\(legacyProfile.id.uuidString).json",
            directoryHint: .notDirectory
        )
        try JSONSerialization.data(
            withJSONObject: document
        ).write(to: profileURL)
        let store = JSONProfileStore(directory: directory)

        var migrated = try #require(
            try await store.load(id: legacyProfile.id)
        )

        #expect(
            migrated.schemaVersion
                == LaunchProfile.currentSchemaVersion
        )
        #expect(migrated.lastUsedAt == nil)

        migrated.name = "Migrated and edited"
        migrated.server.alias = nil
        try await store.save(migrated)
        let persisted = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: profileURL)
            ) as? [String: Any]
        )
        #expect(
            persisted["schemaVersion"] as? Int
                == LaunchProfile.currentSchemaVersion
        )
        #expect(
            (
                persisted["pluginExtension"]
                    as? [String: Any]
            )?["enabled"] as? Bool == true
        )
        #expect(
            (
                persisted["server"]
                    as? [String: Any]
            )?["futureRuntimeOption"] as? String
                == "keep-me"
        )
        #expect(
            (
                persisted["server"]
                    as? [String: Any]
            )?["alias"] is NSNull
        )
    }

    @Test("migrates model memory defaults to global inheritance")
    func migratesMemoryDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var legacyProfile = makeProfile()
        legacyProfile.schemaVersion = 3
        legacyProfile.server.contextSize = nil
        legacyProfile.server.cacheTypeK = nil
        legacyProfile.server.cacheTypeV = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profileURL = directory.appending(
            path: "\(legacyProfile.id.uuidString).json",
            directoryHint: .notDirectory
        )
        try encoder.encode(legacyProfile).write(to: profileURL)
        let store = JSONProfileStore(directory: directory)

        let migrated = try #require(
            try await store.load(id: legacyProfile.id)
        )

        #expect(migrated.schemaVersion == 5)
        #expect(migrated.server.contextSize == nil)
        #expect(migrated.server.cacheTypeK == nil)
        #expect(migrated.server.cacheTypeV == nil)
        let persisted = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: profileURL)
            ) as? [String: Any]
        )
        let server = try #require(
            persisted["server"] as? [String: Any]
        )
        #expect(persisted["schemaVersion"] as? Int == 5)
        #expect(server["contextSize"] is NSNull)
        #expect(server["cacheTypeK"] is NSNull)
        #expect(server["cacheTypeV"] is NSNull)
    }

    @Test("preserves explicit model overrides during global migration")
    func preservesModelOverridesDuringGlobalMigration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var legacyProfile = makeProfile()
        legacyProfile.schemaVersion = 4
        legacyProfile.server.contextSize = 131_072
        legacyProfile.server.cacheTypeK = "f16"
        legacyProfile.server.cacheTypeV = "q4_0"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profileURL = directory.appending(
            path: "\(legacyProfile.id.uuidString).json",
            directoryHint: .notDirectory
        )
        try encoder.encode(legacyProfile).write(to: profileURL)

        let migrated = try #require(
            try await JSONProfileStore(directory: directory).load(
                id: legacyProfile.id
            )
        )

        #expect(migrated.schemaVersion == 5)
        #expect(migrated.server.contextSize == 131_072)
        #expect(migrated.server.cacheTypeK == "f16")
        #expect(migrated.server.cacheTypeV == "q4_0")
    }

    @Test("deletes only the requested profile file")
    func deletesRequestedProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeProfile()
        var second = makeProfile(id: UUID())
        second.name = "Second"
        let store = JSONProfileStore(directory: directory)
        try await store.save(first)
        try await store.save(second)

        try await store.delete(id: first.id)

        #expect(try await store.load(id: first.id) == nil)
        #expect(try await store.load(id: second.id) == second)
        #expect(try await store.loadAll() == [second])
    }

    @Test("exports readable JSON and imports collisions without overwriting")
    func exportsAndImportsWithoutOverwriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockProfileTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = makeProfile()
        let store = JSONProfileStore(directory: directory)
        try await store.save(original)
        let exported = try #require(
            try await store.exportData(id: original.id)
        )
        let importedAt = Date(timeIntervalSince1970: 1_785_315_000)

        let imported = try await store.importProfile(
            from: exported,
            importedAt: importedAt
        )

        #expect(imported.id != original.id)
        #expect(imported.name == "\(original.name) Imported")
        #expect(imported.createdAt == importedAt)
        #expect(imported.updatedAt == importedAt)
        #expect(imported.lastUsedAt == nil)
        #expect(try await store.load(id: original.id) == original)
        #expect(try await store.load(id: imported.id) == imported)
        #expect(try await store.loadAll().count == 2)
    }
}
