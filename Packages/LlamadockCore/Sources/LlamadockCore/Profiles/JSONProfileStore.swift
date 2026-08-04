import Foundation

public enum ProfileStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public actor JSONProfileStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var sourceDocuments: [UUID: [String: Any]] = [:]

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
        let destination = fileURL(for: profile.id)
        var typedDocument = try jsonDocument(
            from: encoder.encode(profile)
        )
        insertExplicitNulls(
            for: profile,
            into: &typedDocument
        )
        let originalDocument = sourceDocuments[profile.id]
            ?? (try? jsonDocument(at: destination))
            ?? [:]
        let document = deepMerge(
            original: originalDocument,
            replacement: typedDocument
        )
        let data = try encodedJSON(document)
        try atomicallyWrite(data, to: destination)
        sourceDocuments[profile.id] = document
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

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        sourceDocuments.removeValue(forKey: id)
    }

    public func exportData(id: UUID) throws -> Data? {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    public func importProfile(
        from data: Data,
        importedAt: Date = Date()
    ) throws -> LaunchProfile {
        var document = try jsonDocument(from: data)
        var profile = try decodeProfile(document: &document)

        if fileManager.fileExists(atPath: fileURL(for: profile.id).path) {
            profile.id = UUID()
            profile.name = "\(profile.name) Imported"
            profile.createdAt = importedAt
            profile.updatedAt = importedAt
            profile.lastUsedAt = nil
            document["id"] = profile.id.uuidString
        }

        sourceDocuments[profile.id] = document
        try save(profile)
        return profile
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(
            path: "\(id.uuidString).json",
            directoryHint: .notDirectory
        )
    }

    private func decodeProfile(at url: URL) throws -> LaunchProfile {
        var document = try jsonDocument(at: url)
        let originalSchemaVersion = document["schemaVersion"] as? Int
        let profile = try decodeProfile(document: &document)
        sourceDocuments[profile.id] = document
        if originalSchemaVersion != LaunchProfile.currentSchemaVersion {
            try atomicallyWrite(
                try encodedJSON(document),
                to: url
            )
        }
        return profile
    }

    private func decodeProfile(
        document: inout [String: Any]
    ) throws -> LaunchProfile {
        guard let schemaVersion = document["schemaVersion"] as? Int else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Profile schemaVersion must be an integer."
                )
            )
        }
        guard
            schemaVersion >= 1,
            schemaVersion <= LaunchProfile.currentSchemaVersion
        else {
            throw ProfileStoreError.unsupportedSchemaVersion(
                schemaVersion
            )
        }

        if schemaVersion < 3 {
            if document["router"] == nil {
                let id = (document["id"] as? String)
                    .flatMap(UUID.init(uuidString:))
                    ?? UUID()
                let name = document["name"] as? String ?? "Model"
                document["router"] = [
                    "identifier": RouterModelOptions.defaultIdentifier(
                        name: name,
                        id: id
                    ),
                    "isEnabled": true,
                    "loadOnStartup": false,
                    "stopTimeout": NSNull(),
                ]
            }
        }
        if schemaVersion < 4 {
            var server = document["server"] as? [String: Any] ?? [:]
            if server["contextSize"] == nil
                || server["contextSize"] is NSNull
            {
                server["contextSize"] = GlobalModelOptions.defaultContextSize
            }
            if server["cacheTypeK"] == nil
                || server["cacheTypeK"] is NSNull
            {
                server["cacheTypeK"] =
                    GlobalModelOptions.defaultKVCacheType.rawValue
            }
            if server["cacheTypeV"] == nil
                || server["cacheTypeV"] is NSNull
            {
                server["cacheTypeV"] =
                    GlobalModelOptions.defaultKVCacheType.rawValue
            }
            document["server"] = server
        }
        if schemaVersion < 5 {
            var server = document["server"] as? [String: Any] ?? [:]
            if server["contextSize"] as? Int
                == GlobalModelOptions.defaultContextSize
            {
                server["contextSize"] = NSNull()
            }
            if server["cacheTypeK"] as? String
                == GlobalModelOptions.defaultKVCacheType.rawValue
            {
                server["cacheTypeK"] = NSNull()
            }
            if server["cacheTypeV"] as? String
                == GlobalModelOptions.defaultKVCacheType.rawValue
            {
                server["cacheTypeV"] = NSNull()
            }
            document["server"] = server
        }
        if schemaVersion < LaunchProfile.currentSchemaVersion {
            document["schemaVersion"] = LaunchProfile.currentSchemaVersion
        }
        let normalizedData = try encodedJSON(document)
        let profile = try decoder.decode(
            LaunchProfile.self,
            from: normalizedData
        )
        guard profile.schemaVersion == LaunchProfile.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(
                profile.schemaVersion
            )
        }
        return profile
    }

    private func jsonDocument(
        at url: URL
    ) throws -> [String: Any] {
        try jsonDocument(from: Data(contentsOf: url))
    }

    private func jsonDocument(
        from data: Data
    ) throws -> [String: Any] {
        guard
            let document = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Profile JSON must be an object."
                )
            )
        }
        return document
    }

    private func encodedJSON(
        _ document: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: document,
            options: [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
        )
    }

    private func insertExplicitNulls(
        for profile: LaunchProfile,
        into document: inout [String: Any]
    ) {
        document["lastUsedAt"] = profile.lastUsedAt == nil
            ? NSNull()
            : document["lastUsedAt"]

        var model = document["model"] as? [String: Any] ?? [:]
        if profile.model.mmprojPath == nil {
            model["mmprojPath"] = NSNull()
        }
        if profile.model.draftPath == nil {
            model["draftPath"] = NSNull()
        }
        document["model"] = model

        var router = document["router"] as? [String: Any] ?? [:]
        if profile.router.stopTimeout == nil {
            router["stopTimeout"] = NSNull()
        }
        document["router"] = router

        var server = document["server"] as? [String: Any] ?? [:]
        let optionalServerValues: [(String, Bool)] = [
            ("alias", profile.server.alias == nil),
            ("contextSize", profile.server.contextSize == nil),
            ("gpuLayers", profile.server.gpuLayers == nil),
            ("threads", profile.server.threads == nil),
            ("parallel", profile.server.parallel == nil),
            ("batchSize", profile.server.batchSize == nil),
            ("ubatchSize", profile.server.ubatchSize == nil),
            ("flashAttention", profile.server.flashAttention == nil),
            ("cacheTypeK", profile.server.cacheTypeK == nil),
            ("cacheTypeV", profile.server.cacheTypeV == nil),
            ("systemPrompt", profile.server.systemPrompt == nil),
        ]
        for (key, isNil) in optionalServerValues where isNil {
            server[key] = NSNull()
        }
        document["server"] = server

        var sampling = document["sampling"] as? [String: Any] ?? [:]
        let optionalSamplingValues: [(String, Bool)] = [
            ("temperature", profile.sampling.temperature == nil),
            ("topK", profile.sampling.topK == nil),
            ("topP", profile.sampling.topP == nil),
            ("minP", profile.sampling.minP == nil),
            ("repeatPenalty", profile.sampling.repeatPenalty == nil),
            ("seed", profile.sampling.seed == nil),
        ]
        for (key, isNil) in optionalSamplingValues where isNil {
            sampling[key] = NSNull()
        }
        document["sampling"] = sampling
    }

    private func deepMerge(
        original: [String: Any],
        replacement: [String: Any]
    ) -> [String: Any] {
        var result = original
        for (key, value) in replacement {
            if
                let originalValue = result[key] as? [String: Any],
                let replacementValue = value as? [String: Any]
            {
                result[key] = deepMerge(
                    original: originalValue,
                    replacement: replacementValue
                )
            } else {
                result[key] = value
            }
        }
        return result
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
