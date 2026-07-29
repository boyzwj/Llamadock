import Testing
@testable import LlamadockCore

@Suite("Hugging Face reference parser")
struct HuggingFaceReferenceParserTests {
    @Test(
        "normalizes repository URLs, compact quant references, and llama commands",
        arguments: [
            (
                "https://huggingface.co/ggml-org/gemma-3-GGUF",
                HuggingFaceRepositoryReference(
                    repositoryID: "ggml-org/gemma-3-GGUF"
                )
            ),
            (
                "https://huggingface.co/ggml-org/gemma-3-GGUF/tree/dev",
                HuggingFaceRepositoryReference(
                    repositoryID: "ggml-org/gemma-3-GGUF",
                    revision: "dev"
                )
            ),
            (
                "mradermacher/model-GGUF:UD-Q4_K_M",
                HuggingFaceRepositoryReference(
                    repositoryID: "mradermacher/model-GGUF",
                    quantization: "UD-Q4_K_M"
                )
            ),
            (
                "llama serve -hf 'mradermacher/model-GGUF:Q4_K_M'",
                HuggingFaceRepositoryReference(
                    repositoryID: "mradermacher/model-GGUF",
                    quantization: "Q4_K_M"
                )
            ),
            (
                "llama-server --hf-repo=owner/repo-GGUF",
                HuggingFaceRepositoryReference(
                    repositoryID: "owner/repo-GGUF"
                )
            ),
        ]
    )
    func parses(
        input: String,
        expected: HuggingFaceRepositoryReference
    ) throws {
        #expect(try HuggingFaceReferenceParser().parse(input) == expected)
    }

    @Test("rejects non-Hugging Face hosts and unsafe repository forms")
    func rejectsUnsafeReferences() {
        let parser = HuggingFaceReferenceParser()

        #expect(throws: HuggingFaceReferenceError.unsupportedHost("example.com")) {
            try parser.parse("https://example.com/owner/repo")
        }
        #expect(
            throws: HuggingFaceReferenceError.invalidRepositoryID(
                "owner/../repo"
            )
        ) {
            try parser.parse("owner/../repo")
        }
        #expect(
            throws: HuggingFaceReferenceError.invalidQuantization(
                "Q4 K M"
            )
        ) {
            try parser.parse("owner/repo:Q4 K M")
        }
        #expect(throws: HuggingFaceReferenceError.missingRepository) {
            try parser.parse("llama serve -hf")
        }
        #expect(throws: HuggingFaceReferenceError.unterminatedQuote) {
            try parser.parse("llama serve -hf 'owner/repo")
        }
    }
}
