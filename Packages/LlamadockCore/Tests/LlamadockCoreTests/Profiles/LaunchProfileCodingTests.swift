import Foundation
import Testing
@testable import LlamadockCore

@Suite("Launch profile coding")
struct LaunchProfileCodingTests {
    @Test("round-trips the readable versioned schema")
    func roundTripsSchema() throws {
        let profile = makeProfile()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(LaunchProfile.self, from: data)
        let json = String(decoding: data, as: UTF8.self)

        #expect(decoded == profile)
        #expect(json.contains(#""schemaVersion" : 1"#))
        #expect(json.contains(#""mainPath" : "/Models/My Model.gguf""#))
        #expect(!json.contains("file:///"))
        #expect(json.contains(#""extraArguments" : ["#))
    }
}

func makeProfile(
    id: UUID = UUID(uuidString: "9D4A85F7-2A82-4E46-A49B-A9C879F0DB4F")!
) -> LaunchProfile {
    LaunchProfile(
        id: id,
        name: "Coding 32K",
        model: ModelPaths(
            mainPath: "/Models/My Model.gguf",
            mmprojPath: nil,
            draftPath: nil
        ),
        runtimeSelection: RuntimeSelection(
            policy: .specific,
            runtimeID: "custom:test"
        ),
        server: ServerOptions(
            alias: "qwen-local",
            host: "127.0.0.1",
            port: 8_080,
            contextSize: 32_768,
            gpuLayers: 99,
            threads: 8,
            parallel: 1,
            batchSize: 2_048,
            ubatchSize: 512,
            flashAttention: true,
            cacheTypeK: "q8_0",
            cacheTypeV: "q8_0",
            systemPrompt: nil
        ),
        sampling: SamplingOptions(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
            minP: 0.05,
            repeatPenalty: 1.05,
            seed: -1
        ),
        extraArguments: ["--jinja"],
        createdAt: Date(timeIntervalSince1970: 1_785_315_000),
        updatedAt: Date(timeIntervalSince1970: 1_785_315_100)
    )
}
