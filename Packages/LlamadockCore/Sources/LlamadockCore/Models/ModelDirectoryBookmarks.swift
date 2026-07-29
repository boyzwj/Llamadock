import Foundation

public struct ModelDirectoryBookmarkRecord:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public var displayName: String
    public var originalPath: String
    public var bookmarkData: Data
    public let addedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        originalPath: String,
        bookmarkData: Data,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.originalPath = originalPath
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
    }
}

public struct ResolvedModelDirectory:
    Equatable,
    Identifiable,
    Sendable
{
    public let record: ModelDirectoryBookmarkRecord
    public let url: URL

    public init(
        record: ModelDirectoryBookmarkRecord,
        url: URL
    ) {
        self.record = record
        self.url = url.standardizedFileURL
    }

    public var id: UUID {
        record.id
    }
}

public struct ModelDirectoryResolutionIssue:
    Equatable,
    Identifiable,
    Sendable
{
    public let record: ModelDirectoryBookmarkRecord
    public let reason: String

    public init(
        record: ModelDirectoryBookmarkRecord,
        reason: String
    ) {
        self.record = record
        self.reason = reason
    }

    public var id: UUID {
        record.id
    }
}

public struct ModelDirectoryStoreSnapshot:
    Equatable,
    Sendable
{
    public let records: [ModelDirectoryBookmarkRecord]
    public let directories: [ResolvedModelDirectory]
    public let issues: [ModelDirectoryResolutionIssue]

    public init(
        records: [ModelDirectoryBookmarkRecord],
        directories: [ResolvedModelDirectory],
        issues: [ModelDirectoryResolutionIssue]
    ) {
        self.records = records
        self.directories = directories
        self.issues = issues
    }
}

public struct ModelDirectoryBookmarkResolution:
    Equatable,
    Sendable
{
    public let url: URL
    public let isStale: Bool

    public init(
        url: URL,
        isStale: Bool
    ) {
        self.url = url.standardizedFileURL
        self.isStale = isStale
    }
}

public protocol ModelDirectoryBookmarkCoding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(
        _ data: Data
    ) throws -> ModelDirectoryBookmarkResolution
}

public struct SecurityScopedModelDirectoryBookmarkCodec:
    ModelDirectoryBookmarkCoding,
    Sendable
{
    public init() {}

    public func makeBookmark(
        for url: URL
    ) throws -> Data {
        let standardBookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let securityScopedBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return try PropertyListEncoder().encode(
            BookmarkEnvelope(
                schemaVersion: 1,
                securityScopedBookmark: securityScopedBookmark,
                standardBookmark: standardBookmark
            )
        )
    }

    public func resolveBookmark(
        _ data: Data
    ) throws -> ModelDirectoryBookmarkResolution {
        if
            let envelope = try? PropertyListDecoder().decode(
                BookmarkEnvelope.self,
                from: data
            ),
            envelope.schemaVersion == 1
        {
            if let scoped = envelope.securityScopedBookmark {
                do {
                    return try resolve(
                        scoped,
                        options: [
                            .withSecurityScope,
                            .withoutUI,
                        ]
                    )
                } catch {
                    // Ad-hoc, non-sandboxed builds can create scoped bookmark
                    // data that Foundation cannot resolve after relaunch.
                }
            }
            return try resolve(
                envelope.standardBookmark,
                options: [.withoutUI]
            )
        }

        let legacyResolution: ModelDirectoryBookmarkResolution
        do {
            legacyResolution = try resolve(
                data,
                options: [
                    .withSecurityScope,
                    .withoutUI,
                ]
            )
        } catch {
            legacyResolution = try resolve(
                data,
                options: [.withoutUI]
            )
        }
        return ModelDirectoryBookmarkResolution(
            url: legacyResolution.url,
            isStale: true
        )
    }

    private func resolve(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ModelDirectoryBookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ModelDirectoryBookmarkResolution(
            url: url,
            isStale: isStale
        )
    }
}

public enum ModelDirectoryStoreError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedSchemaVersion(Int)
    case notReadableDirectory(URL)
    case symbolicLinkDirectory(URL)
    case invalidRecord(id: UUID, reason: String)
}

extension ModelDirectoryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported settings schema: \(version)."
        case .notReadableDirectory(let url):
            "The model location is not a readable directory: \(url.path)"
        case .symbolicLinkDirectory(let url):
            "Symbolic-link model roots are not supported: \(url.path)"
        case .invalidRecord(let id, let reason):
            "Model directory bookmark \(id.uuidString) is invalid: \(reason)"
        }
    }
}

public actor JSONModelDirectoryStore {
    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let bookmarkCodec: any ModelDirectoryBookmarkCoding
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        bookmarkCodec: any ModelDirectoryBookmarkCoding =
            SecurityScopedModelDirectoryBookmarkCodec(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.bookmarkCodec = bookmarkCodec
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func snapshot() throws -> ModelDirectoryStoreSnapshot {
        var document = try loadDocument()
        var directories: [ResolvedModelDirectory] = []
        var issues: [ModelDirectoryResolutionIssue] = []
        var didRefreshBookmark = false

        for index in document.modelDirectories.indices {
            var record = document.modelDirectories[index]
            do {
                let resolution: ModelDirectoryBookmarkResolution
                do {
                    resolution = try bookmarkCodec.resolveBookmark(
                        record.bookmarkData
                    )
                } catch {
                    resolution = try recoverFromOriginalPath(record)
                    record.bookmarkData = try bookmarkCodec.makeBookmark(
                        for: resolution.url
                    )
                    record.originalPath =
                        resolution.url.standardizedFileURL.path
                    record.displayName = displayName(
                        for: resolution.url
                    )
                    document.modelDirectories[index] = record
                    didRefreshBookmark = true
                }

                try withSecurityScopedAccess(to: resolution.url) {
                    try validateDirectory(resolution.url)
                }

                if resolution.isStale {
                    record.bookmarkData = try bookmarkCodec.makeBookmark(
                        for: resolution.url
                    )
                    record.originalPath =
                        resolution.url.standardizedFileURL.path
                    record.displayName = displayName(
                        for: resolution.url
                    )
                    document.modelDirectories[index] = record
                    didRefreshBookmark = true
                }
                directories.append(
                    ResolvedModelDirectory(
                        record: record,
                        url: resolution.url
                    )
                )
            } catch {
                issues.append(
                    ModelDirectoryResolutionIssue(
                        record: record,
                        reason: diagnosticDescription(error)
                    )
                )
            }
        }

        if didRefreshBookmark {
            try save(document)
        }
        return ModelDirectoryStoreSnapshot(
            records: document.modelDirectories,
            directories: directories,
            issues: issues
        )
    }

    @discardableResult
    public func addDirectory(
        _ url: URL,
        id: UUID = UUID(),
        addedAt: Date = Date()
    ) throws -> ModelDirectoryStoreSnapshot {
        let standardizedURL = url.standardizedFileURL
        try validateDirectory(standardizedURL)

        let existingSnapshot = try snapshot()
        var document = try loadDocument()
        if
            existingSnapshot.directories.contains(
                where: { $0.url == standardizedURL }
            )
        {
            return ModelDirectoryStoreSnapshot(
                records: document.modelDirectories,
                directories: existingSnapshot.directories,
                issues: existingSnapshot.issues
            )
        }
        if
            document.modelDirectories.contains(
                where: { $0.originalPath == standardizedURL.path }
            )
        {
            return existingSnapshot
        }

        let record = ModelDirectoryBookmarkRecord(
            id: id,
            displayName: displayName(for: standardizedURL),
            originalPath: standardizedURL.path,
            bookmarkData: try bookmarkCodec.makeBookmark(
                for: standardizedURL
            ),
            addedAt: addedAt
        )
        document.modelDirectories.append(record)
        document.modelDirectories.sort {
            if $0.addedAt == $1.addedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.addedAt < $1.addedAt
        }
        try save(document)
        return try snapshot()
    }

    @discardableResult
    public func removeDirectory(
        id: UUID
    ) throws -> ModelDirectoryStoreSnapshot {
        var document = try loadDocument()
        document.modelDirectories.removeAll { $0.id == id }
        try save(document)
        return try snapshot()
    }

    private func loadDocument() throws -> ModelLibrarySettingsDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ModelLibrarySettingsDocument(
                schemaVersion: Self.currentSchemaVersion,
                modelDirectories: []
            )
        }
        let document = try decoder.decode(
            ModelLibrarySettingsDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard
            document.schemaVersion == Self.currentSchemaVersion
        else {
            throw ModelDirectoryStoreError.unsupportedSchemaVersion(
                document.schemaVersion
            )
        }
        try validate(document)
        return document
    }

    private func validate(
        _ document: ModelLibrarySettingsDocument
    ) throws {
        var ids = Set<UUID>()
        for record in document.modelDirectories {
            guard ids.insert(record.id).inserted else {
                throw ModelDirectoryStoreError.invalidRecord(
                    id: record.id,
                    reason: "duplicate ID"
                )
            }
            guard
                !record.displayName.isEmpty,
                record.originalPath.hasPrefix("/"),
                !record.bookmarkData.isEmpty
            else {
                throw ModelDirectoryStoreError.invalidRecord(
                    id: record.id,
                    reason: "name, absolute original path, and bookmark data are required"
                )
            }
        }
    }

    private func validateDirectory(
        _ url: URL
    ) throws {
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isReadableKey,
                .isSymbolicLinkKey,
            ]
        )
        guard values.isSymbolicLink != true else {
            throw ModelDirectoryStoreError.symbolicLinkDirectory(url)
        }
        guard
            values.isDirectory == true,
            values.isReadable != false
        else {
            throw ModelDirectoryStoreError.notReadableDirectory(url)
        }
    }

    private func recoverFromOriginalPath(
        _ record: ModelDirectoryBookmarkRecord
    ) throws -> ModelDirectoryBookmarkResolution {
        let url = URL(
            filePath: record.originalPath,
            directoryHint: .isDirectory
        ).standardizedFileURL
        try validateDirectory(url)
        return ModelDirectoryBookmarkResolution(
            url: url,
            isStale: false
        )
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        _ operation: () throws -> T
    ) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    private func displayName(
        for url: URL
    ) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func save(
        _ document: ModelLibrarySettingsDocument
    ) throws {
        try validate(document)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        let temporaryURL = directory.appending(
            path: ".settings.\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try data.write(
                to: temporaryURL,
                options: .withoutOverwriting
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: fileURL
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func diagnosticDescription(
        _ error: Error
    ) -> String {
        if
            let localized = error as? any LocalizedError,
            let description = localized.errorDescription,
            !description.isEmpty
        {
            return description
        }
        return String(describing: error)
    }
}

private struct ModelLibrarySettingsDocument: Codable {
    let schemaVersion: Int
    var modelDirectories: [ModelDirectoryBookmarkRecord]
}

private struct BookmarkEnvelope: Codable {
    let schemaVersion: Int
    let securityScopedBookmark: Data?
    let standardBookmark: Data
}
