import Foundation

public enum ProfileStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public actor JSONProfileStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directory: URL,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
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

    public func save(_ profile: LaunchProfile) throws {
        guard profile.schemaVersion == LaunchProfile.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(
                profile.schemaVersion
            )
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(profile)
        try atomicallyWrite(data, to: fileURL(for: profile.id))
    }

    public func load(id: UUID) throws -> LaunchProfile? {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        return try decodeProfile(at: url)
    }

    public func loadAll() throws -> [LaunchProfile] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .map(decodeProfile)
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(
            path: "\(id.uuidString).json",
            directoryHint: .notDirectory
        )
    }

    private func decodeProfile(at url: URL) throws -> LaunchProfile {
        let profile = try decoder.decode(
            LaunchProfile.self,
            from: Data(contentsOf: url)
        )
        guard profile.schemaVersion == LaunchProfile.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(
                profile.schemaVersion
            )
        }
        return profile
    }

    private func atomicallyWrite(_ data: Data, to destination: URL) throws {
        let temporaryURL = directory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)

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
