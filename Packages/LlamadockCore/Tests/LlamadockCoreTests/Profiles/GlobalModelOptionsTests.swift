import Testing
@testable import LlamadockCore

@Suite("Global model options")
struct GlobalModelOptionsTests {
    @Test("uses documented memory-safe defaults")
    func usesSafeDefaults() {
        let options = GlobalModelOptions()

        #expect(options.contextSize == 32_768)
        #expect(options.cacheTypeK == .q8_0)
        #expect(options.cacheTypeV == .q8_0)
        #expect(options.gpuLayers == .automatic)
        #expect(options.kvOffload)
        #expect(options.fitToMemory)
        #expect(options.fitTargetMiB == 1_024)
        #expect(options.fitContextSize == 4_096)
        #expect(options.flashAttention == .automatic)
        #expect(options.threads == -1)
        #expect(options.parallel == -1)
        #expect(options.batchSize == 2_048)
        #expect(options.ubatchSize == 512)
    }

    @Test("normalizes context and batch boundaries")
    func normalizesBoundaries() {
        var options = GlobalModelOptions(
            contextSize: 1_048_000,
            fitTargetMiB: 70_000,
            fitContextSize: 2_000_000,
            threads: 999,
            parallel: 999,
            batchSize: 16,
            ubatchSize: 4_096
        )

        #expect(options.contextSize == 1_047_552)
        #expect(options.fitContextSize == 1_047_552)
        #expect(options.fitTargetMiB == 65_536)
        #expect(options.threads == 256)
        #expect(options.parallel == 64)
        #expect(options.batchSize == 32)
        #expect(options.ubatchSize == 32)

        options.contextSize = 0
        options.normalize()
        #expect(options.contextSize == 1_024)
        #expect(options.fitContextSize == 1_024)
    }

    @Test("lists every llama.cpp KV cache type exposed by the UI")
    func listsKVCacheTypes() {
        #expect(
            KVCacheType.allCases.map(\.rawValue) == [
                "f32", "f16", "bf16", "q8_0", "q4_0", "q4_1",
                "iq4_nl", "q5_0", "q5_1",
            ]
        )
    }
}
