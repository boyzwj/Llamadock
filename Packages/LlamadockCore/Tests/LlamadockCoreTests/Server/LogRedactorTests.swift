import Testing
@testable import LlamadockCore

@Suite("Log redaction")
struct LogRedactorTests {
    @Test("redacts authorization headers, tokens, and signed URL queries")
    func redactsSecrets() {
        let input = """
        Authorization: Bearer hf_super_secret
        HF_TOKEN=hf_another_secret
        standalone hf_standalone_secret
        GET https://cdn.example/model.gguf?X-Amz-Signature=secret&token=also-secret
        """

        let output = LogRedactor.redact(input)

        #expect(output.contains("Authorization: Bearer <redacted>"))
        #expect(output.contains("HF_TOKEN=<redacted>"))
        #expect(output.contains("https://cdn.example/model.gguf?<redacted>"))
        #expect(!output.contains("hf_super_secret"))
        #expect(!output.contains("hf_another_secret"))
        #expect(!output.contains("hf_standalone_secret"))
        #expect(!output.contains("X-Amz-Signature"))
        #expect(!output.contains("also-secret"))
    }

    @Test("leaves ordinary text unchanged")
    func leavesOrdinaryText() {
        #expect(LogRedactor.redact("server ready on 127.0.0.1") == "server ready on 127.0.0.1")
    }
}
