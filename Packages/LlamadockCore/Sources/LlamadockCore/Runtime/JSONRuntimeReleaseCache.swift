import Foundation

public enum RuntimeReleaseCacheError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidEntry(String)
}

public actor JSONRuntimeReleaseCache: RuntimeReleaseCaching {
    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let selector = GitHubRuntimeAssetSelector()

    public init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
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

    public func load() throws -> CachedRuntimeRelease? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let document = try decoder.decode(
            CacheDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard
            document.schemaVersion == Self.currentSchemaVersion
        else {
            throw RuntimeReleaseCacheError.unsupportedSchemaVersion(
                document.schemaVersion
            )
        }
        try validate(document.entry)
        return document.entry
    }

    public func save(_ entry: CachedRuntimeRelease) throws {
        try validate(entry)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(
            CacheDocument(
                schemaVersion: Self.currentSchemaVersion,
                entry: entry
            )
        )
        try atomicallyWrite(data, to: fileURL)
    }

    private func validate(
        _ entry: CachedRuntimeRelease
    ) throws {
        let parsedTag: LlamaBuildTag
        do {
            parsedTag = try LlamaBuildTag(
                parsing: entry.release.tag
            )
        } catch {
            throw RuntimeReleaseCacheError.invalidEntry(
                error.localizedDescription
            )
        }
        guard parsedTag == entry.release.buildTag else {
            throw RuntimeReleaseCacheError.invalidEntry(
                "The cached tag and build do not match."
            )
        }
        guard entry.release.asset.size > 0 else {
            throw RuntimeReleaseCacheError.invalidEntry(
                "The cached asset size must be positive."
            )
        }
        do {
            _ = try selector.selectMacOSAppleSiliconAsset(
                from: [entry.release.asset]
            )
        } catch {
            throw RuntimeReleaseCacheError.invalidEntry(
                error.localizedDescription
            )
        }
    }

    private func atomicallyWrite(
        _ data: Data,
        to destination: URL
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try data.write(
                to: temporaryURL,
                options: .withoutOverwriting
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: destination
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private struct CacheDocument: Codable {
    let schemaVersion: Int
    let entry: CachedRuntimeRelease
}
