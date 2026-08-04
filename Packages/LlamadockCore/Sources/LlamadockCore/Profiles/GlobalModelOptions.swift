import Foundation

public enum KVCacheType: String, Codable, CaseIterable, Sendable {
    case f32
    case f16
    case bf16
    case q8_0
    case q4_0
    case q4_1
    case iq4_nl
    case q5_0
    case q5_1
}

public enum FlashAttentionMode: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case enabled = "on"
    case disabled = "off"
}

public enum GPULayersMode: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case all
    case cpuOnly = "0"
}

public struct GlobalModelOptions: Codable, Equatable, Sendable {
    public static let minimumContextSize = 1_024
    public static let maximumContextSize = 1_048_576
    public static let contextSizeStep = 1_024
    public static let defaultContextSize = 32_768
    public static let defaultKVCacheType = KVCacheType.q8_0

    public var contextSize: Int
    public var cacheTypeK: KVCacheType
    public var cacheTypeV: KVCacheType
    public var gpuLayers: GPULayersMode
    public var kvOffload: Bool
    public var fitToMemory: Bool
    public var fitTargetMiB: Int
    public var fitContextSize: Int
    public var flashAttention: FlashAttentionMode
    public var threads: Int
    public var parallel: Int
    public var batchSize: Int
    public var ubatchSize: Int

    public init(
        contextSize: Int = GlobalModelOptions.defaultContextSize,
        cacheTypeK: KVCacheType = GlobalModelOptions.defaultKVCacheType,
        cacheTypeV: KVCacheType = GlobalModelOptions.defaultKVCacheType,
        gpuLayers: GPULayersMode = .automatic,
        kvOffload: Bool = true,
        fitToMemory: Bool = true,
        fitTargetMiB: Int = 1_024,
        fitContextSize: Int = 4_096,
        flashAttention: FlashAttentionMode = .automatic,
        threads: Int = -1,
        parallel: Int = -1,
        batchSize: Int = 2_048,
        ubatchSize: Int = 512
    ) {
        self.contextSize = contextSize
        self.cacheTypeK = cacheTypeK
        self.cacheTypeV = cacheTypeV
        self.gpuLayers = gpuLayers
        self.kvOffload = kvOffload
        self.fitToMemory = fitToMemory
        self.fitTargetMiB = fitTargetMiB
        self.fitContextSize = fitContextSize
        self.flashAttention = flashAttention
        self.threads = threads
        self.parallel = parallel
        self.batchSize = batchSize
        self.ubatchSize = ubatchSize
        normalize()
    }

    public mutating func normalize() {
        contextSize = Self.roundedContextSize(contextSize)
        fitContextSize = min(
            Self.roundedContextSize(fitContextSize),
            contextSize
        )
        fitTargetMiB = min(max(fitTargetMiB, 0), 65_536)
        threads = threads == -1 ? -1 : min(max(threads, 1), 256)
        parallel = parallel == -1 ? -1 : min(max(parallel, 1), 64)
        batchSize = min(max(batchSize, 32), 8_192)
        ubatchSize = min(max(ubatchSize, 32), batchSize)
    }

    public static func roundedContextSize(_ value: Int) -> Int {
        let bounded = min(
            max(value, minimumContextSize),
            maximumContextSize
        )
        let steps = Double(bounded) / Double(contextSizeStep)
        return Int(steps.rounded()) * contextSizeStep
    }
}
