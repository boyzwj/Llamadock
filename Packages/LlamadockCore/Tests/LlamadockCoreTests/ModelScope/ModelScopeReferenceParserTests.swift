import Testing
@testable import LlamadockCore

@Suite("ModelScope reference parser")
struct ModelScopeReferenceParserTests {
    @Test(
        "normalizes repository URLs and compact quant references",
        arguments: [
            (
                "https://modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF",
                HuggingFaceRepositoryReference(
                    repositoryID: "Qwen/Qwen3-0.6B-GGUF",
                    revision: "master"
                )
            ),
            (
                "https://www.modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF/files",
                HuggingFaceRepositoryReference(
                    repositoryID: "Qwen/Qwen3-0.6B-GGUF",
                    revision: "master"
                )
            ),
            (
                "unsloth/model-GGUF:Q4_K_M",
                HuggingFaceRepositoryReference(
                    repositoryID: "unsloth/model-GGUF",
                    revision: "master",
                    quantization: "Q4_K_M"
                )
            ),
        ]
    )
    func parses(
        input: String,
        expected: HuggingFaceRepositoryReference
    ) throws {
        #expect(
            try ModelScopeReferenceParser().parse(input)
                == expected
        )
    }

    @Test("rejects unsupported hosts and unsafe references")
    func rejectsUnsafeReferences() {
        let parser = ModelScopeReferenceParser()

        #expect(
            throws: ModelScopeReferenceError
                .unsupportedHost("example.com")
        ) {
            try parser.parse(
                "https://example.com/models/owner/repo"
            )
        }
        #expect(
            throws: ModelScopeReferenceError
                .invalidRepositoryID("owner/../repo")
        ) {
            try parser.parse("owner/../repo")
        }
        #expect(
            throws: ModelScopeReferenceError
                .invalidQuantization("Q4 K M")
        ) {
            try parser.parse("owner/repo:Q4 K M")
        }
    }
}
