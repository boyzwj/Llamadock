import Foundation
import Testing
@testable import LlamadockCore

@Suite("Model directory bookmark store")
struct ModelDirectoryBookmarkStoreTests {
    @Test("persists, deduplicates, and removes external model roots")
    func persistsDirectoryBookmarks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try makeDirectory(
            named: "Models A",
            under: fixture.root
        )
        let second = try makeDirectory(
            named: "Models B",
            under: fixture.root
        )
        let firstID = UUID()
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = JSONModelDirectoryStore(
            fileURL: fixture.settings,
            bookmarkCodec: TestBookmarkCodec()
        )

        var snapshot = try await store.addDirectory(
            first,
            id: firstID,
            addedAt: firstDate
        )
        snapshot = try await store.addDirectory(first)
        snapshot = try await store.addDirectory(second)

        #expect(snapshot.records.count == 2)
        #expect(snapshot.directories.map(\.url) == [first, second])
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.records.first?.id == firstID)
        #expect(snapshot.records.first?.addedAt == firstDate)

        let restoredStore = JSONModelDirectoryStore(
            fileURL: fixture.settings,
            bookmarkCodec: TestBookmarkCodec()
        )
        snapshot = try await restoredStore.snapshot()

        #expect(snapshot.directories.map(\.url) == [first, second])

        snapshot = try await restoredStore.removeDirectory(
            id: firstID
        )
        #expect(snapshot.records.count == 1)
        #expect(snapshot.directories.map(\.url) == [second])
    }

    @Test("refreshes stale bookmarks and keeps broken records visible")
    func refreshesStaleBookmarks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try makeDirectory(
            named: "Models",
            under: fixture.root
        )
        let staleID = UUID()
        let brokenID = UUID()
        let document = TestSettingsDocument(
            schemaVersion: 1,
            modelDirectories: [
                ModelDirectoryBookmarkRecord(
                    id: staleID,
                    displayName: "Old Name",
                    originalPath: "/old/path",
                    bookmarkData: Data(
                        "stale:\(directory.path)".utf8
                    ),
                    addedAt: Date(timeIntervalSince1970: 1)
                ),
                ModelDirectoryBookmarkRecord(
                    id: brokenID,
                    displayName: "Unavailable",
                    originalPath: "/missing",
                    bookmarkData: Data("broken".utf8),
                    addedAt: Date(timeIntervalSince1970: 2)
                ),
            ]
        )
        try write(document, to: fixture.settings)
        let store = JSONModelDirectoryStore(
            fileURL: fixture.settings,
            bookmarkCodec: TestBookmarkCodec()
        )

        let snapshot = try await store.snapshot()

        #expect(snapshot.directories.count == 1)
        #expect(snapshot.directories.first?.id == staleID)
        #expect(snapshot.directories.first?.url == directory)
        #expect(
            snapshot.directories.first?.record.displayName
                == "Models"
        )
        #expect(snapshot.issues.count == 1)
        #expect(snapshot.issues.first?.id == brokenID)
        #expect(snapshot.issues.first?.reason.isEmpty == false)

        let persisted = try readDocument(from: fixture.settings)
        let refreshed = try #require(
            persisted.modelDirectories.first {
                $0.id == staleID
            }
        )
        #expect(
            String(data: refreshed.bookmarkData, encoding: .utf8)
                == "fresh:\(directory.path)"
        )
        #expect(refreshed.originalPath == directory.path)
    }

    @Test("rejects unsupported settings schemas")
    func rejectsUnsupportedSchema() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write(
            TestSettingsDocument(
                schemaVersion: 99,
                modelDirectories: []
            ),
            to: fixture.settings
        )
        let store = JSONModelDirectoryStore(
            fileURL: fixture.settings,
            bookmarkCodec: TestBookmarkCodec()
        )

        do {
            _ = try await store.snapshot()
            Issue.record("Expected an unsupported schema error.")
        } catch let error as ModelDirectoryStoreError {
            #expect(error == .unsupportedSchemaVersion(99))
        }
    }

    @Test("recovers an obsolete bookmark from a still-readable original path")
    func recoversObsoleteBookmark() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try makeDirectory(
            named: "Recoverable",
            under: fixture.root
        )
        let id = UUID()
        try write(
            TestSettingsDocument(
                schemaVersion: 1,
                modelDirectories: [
                    ModelDirectoryBookmarkRecord(
                        id: id,
                        displayName: "Old",
                        originalPath: directory.path,
                        bookmarkData: Data("broken".utf8),
                        addedAt: Date(timeIntervalSince1970: 1)
                    )
                ]
            ),
            to: fixture.settings
        )
        let store = JSONModelDirectoryStore(
            fileURL: fixture.settings,
            bookmarkCodec: TestBookmarkCodec()
        )

        let snapshot = try await store.snapshot()

        #expect(snapshot.directories.map(\.url) == [directory])
        #expect(snapshot.issues.isEmpty)
        let persisted = try readDocument(from: fixture.settings)
        #expect(
            String(
                data: try #require(
                    persisted.modelDirectories.first?.bookmarkData
                ),
                encoding: .utf8
            ) == "fresh:\(directory.path)"
        )
    }

    @Test("production bookmark envelope resolves in non-sandboxed tests")
    func productionBookmarkRoundTrip() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try makeDirectory(
            named: "Round Trip",
            under: fixture.root
        )
        let codec = SecurityScopedModelDirectoryBookmarkCodec()

        let data = try codec.makeBookmark(for: directory)
        let resolution = try codec.resolveBookmark(data)

        #expect(resolution.url == directory)
        #expect(!resolution.isStale)
    }

    @Test("marks legacy raw bookmarks stale for envelope migration")
    func marksLegacyBookmarksForMigration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try makeDirectory(
            named: "Legacy",
            under: fixture.root
        )
        let legacy = try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let resolution =
            try SecurityScopedModelDirectoryBookmarkCodec()
                .resolveBookmark(legacy)

        #expect(resolution.url == directory)
        #expect(resolution.isStale)
    }

    private func makeFixture() throws -> (
        root: URL,
        settings: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "LlamadockBookmarks-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return (
            root,
            root.appending(
                path: "settings.json",
                directoryHint: .notDirectory
            )
        )
    }

    private func makeDirectory(
        named name: String,
        under root: URL
    ) throws -> URL {
        let url = root.appending(
            path: name,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url.standardizedFileURL
    }

    private func write(
        _ document: TestSettingsDocument,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
    }

    private func readDocument(
        from url: URL
    ) throws -> TestSettingsDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TestSettingsDocument.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct TestSettingsDocument: Codable {
    let schemaVersion: Int
    var modelDirectories: [ModelDirectoryBookmarkRecord]
}

private enum TestBookmarkError: Error, LocalizedError {
    case invalid

    var errorDescription: String? {
        "The bookmark data is invalid."
    }
}

private struct TestBookmarkCodec:
    ModelDirectoryBookmarkCoding,
    Sendable
{
    func makeBookmark(
        for url: URL
    ) throws -> Data {
        Data("fresh:\(url.standardizedFileURL.path)".utf8)
    }

    func resolveBookmark(
        _ data: Data
    ) throws -> ModelDirectoryBookmarkResolution {
        guard let value = String(data: data, encoding: .utf8) else {
            throw TestBookmarkError.invalid
        }
        if value == "broken" {
            throw TestBookmarkError.invalid
        }
        if value.hasPrefix("stale:") {
            return ModelDirectoryBookmarkResolution(
                url: URL(
                    filePath: String(value.dropFirst("stale:".count)),
                    directoryHint: .isDirectory
                ),
                isStale: true
            )
        }
        guard value.hasPrefix("fresh:") else {
            throw TestBookmarkError.invalid
        }
        return ModelDirectoryBookmarkResolution(
            url: URL(
                filePath: String(value.dropFirst("fresh:".count)),
                directoryHint: .isDirectory
            ),
            isStale: false
        )
    }
}
