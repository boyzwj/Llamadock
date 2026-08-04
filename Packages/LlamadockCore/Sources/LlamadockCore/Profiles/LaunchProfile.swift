import Foundation

public struct ModelPaths: Codable, Equatable, Sendable {
    public var mainPath: String
    public var mmprojPath: String?
    public var draftPath: String?

    public init(
        mainPath: String,
        mmprojPath: String? = nil,
        draftPath: String? = nil
    ) {
        self.mainPath = mainPath
        self.mmprojPath = mmprojPath
        self.draftPath = draftPath
    }
}

public enum RuntimeSelectionPolicy: String, Codable, Sendable {
    case activeManaged
    case specific
}

public struct RuntimeSelection: Codable, Equatable, Sendable {
    public var policy: RuntimeSelectionPolicy
    public var runtimeID: String?

    public init(
        policy: RuntimeSelectionPolicy = .activeManaged,
        runtimeID: String? = nil
    ) {
        self.policy = policy
        self.runtimeID = runtimeID
    }
}

public struct ServerOptions: Codable, Equatable, Sendable {
    public static let defaultPort: UInt16 = 39_281

    public var alias: String?
    public var host: String
    public var port: UInt16
    public var contextSize: Int?
    public var gpuLayers: Int?
    public var threads: Int?
    public var parallel: Int?
    public var batchSize: Int?
    public var ubatchSize: Int?
    public var flashAttention: Bool?
    public var cacheTypeK: String?
    public var cacheTypeV: String?
    public var systemPrompt: String?

    public init(
        alias: String? = nil,
        host: String = "127.0.0.1",
        port: UInt16 = ServerOptions.defaultPort,
        contextSize: Int? = nil,
        gpuLayers: Int? = nil,
        threads: Int? = nil,
        parallel: Int? = nil,
        batchSize: Int? = nil,
        ubatchSize: Int? = nil,
        flashAttention: Bool? = nil,
        cacheTypeK: String? = nil,
        cacheTypeV: String? = nil,
        systemPrompt: String? = nil
    ) {
        self.alias = alias
        self.host = host
        self.port = port
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.threads = threads
        self.parallel = parallel
        self.batchSize = batchSize
        self.ubatchSize = ubatchSize
        self.flashAttention = flashAttention
        self.cacheTypeK = cacheTypeK
        self.cacheTypeV = cacheTypeV
        self.systemPrompt = systemPrompt
    }
}

public struct SamplingOptions: Codable, Equatable, Sendable {
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var repeatPenalty: Double?
    public var seed: Int?

    public init(
        temperature: Double? = nil,
        topK: Int? = nil,
        topP: Double? = nil,
        minP: Double? = nil,
        repeatPenalty: Double? = nil,
        seed: Int? = nil
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.seed = seed
    }
}

public struct RouterModelOptions: Codable, Equatable, Sendable {
    public var identifier: String
    public var isEnabled: Bool
    public var loadOnStartup: Bool
    public var stopTimeout: Int?

    public init(
        identifier: String,
        isEnabled: Bool = true,
        loadOnStartup: Bool = false,
        stopTimeout: Int? = nil
    ) {
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.loadOnStartup = loadOnStartup
        self.stopTimeout = stopTimeout
    }

    public static func defaultIdentifier(
        name: String,
        id: UUID
    ) -> String {
        let normalized = name
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar)
                    ? Character(String(scalar))
                    : "-"
            }
        let collapsed = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if !collapsed.isEmpty {
            return collapsed
        }
        return "model-\(id.uuidString.prefix(8).lowercased())"
    }
}

public struct LaunchProfile: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var model: ModelPaths
    public var router: RouterModelOptions
    public var runtimeSelection: RuntimeSelection
    public var server: ServerOptions
    public var sampling: SamplingOptions
    public var extraArguments: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(
        schemaVersion: Int = LaunchProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        model: ModelPaths,
        router: RouterModelOptions? = nil,
        runtimeSelection: RuntimeSelection = RuntimeSelection(),
        server: ServerOptions = ServerOptions(),
        sampling: SamplingOptions = SamplingOptions(),
        extraArguments: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.model = model
        self.router = router ?? RouterModelOptions(
            identifier: RouterModelOptions.defaultIdentifier(
                name: name,
                id: id
            )
        )
        self.runtimeSelection = runtimeSelection
        self.server = server
        self.sampling = sampling
        self.extraArguments = extraArguments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}
