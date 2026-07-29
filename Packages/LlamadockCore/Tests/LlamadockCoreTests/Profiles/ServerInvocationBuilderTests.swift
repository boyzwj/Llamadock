import Foundation
import Testing
@testable import LlamadockCore

@Suite("Server invocation builder")
struct ServerInvocationBuilderTests {
    @Test("generates Process arguments and display command from one source")
    func generatesInvocation() throws {
        let profile = makeProfile()
        let runtime = makeRuntime(
            supportedFlags: [
                "--model", "--alias", "--host", "--port", "--ctx-size",
                "--n-gpu-layers", "--threads", "--parallel", "--batch-size",
                "--ubatch-size", "--flash-attn", "--cache-type-k",
                "--cache-type-v", "--temp", "--top-k", "--top-p", "--min-p",
                "--repeat-penalty", "--seed",
            ]
        )

        let invocation = try ServerInvocationBuilder().makeServerInvocation(
            profile: profile,
            runtime: runtime
        )

        #expect(invocation.executableURL == runtime.serverURL)
        #expect(
            invocation.arguments
                == [
                    "--model", "/Models/My Model.gguf",
                    "--alias", "qwen-local",
                    "--host", "127.0.0.1",
                    "--port", "8080",
                    "--ctx-size", "32768",
                    "--n-gpu-layers", "99",
                    "--threads", "8",
                    "--parallel", "1",
                    "--batch-size", "2048",
                    "--ubatch-size", "512",
                    "--flash-attn", "on",
                    "--cache-type-k", "q8_0",
                    "--cache-type-v", "q8_0",
                    "--temp", "0.7",
                    "--top-k", "40",
                    "--top-p", "0.95",
                    "--min-p", "0.05",
                    "--repeat-penalty", "1.05",
                    "--seed", "-1",
                    "--jinja",
                ]
        )
        let expectedDisplayCommand = "'/Applications/Llama Runtime/llama-server' "
            + "--model '/Models/My Model.gguf' --alias qwen-local "
            + "--host 127.0.0.1 --port 8080 --ctx-size 32768 "
            + "--n-gpu-layers 99 --threads 8 --parallel 1 "
            + "--batch-size 2048 --ubatch-size 512 --flash-attn on "
            + "--cache-type-k q8_0 --cache-type-v q8_0 --temp 0.7 "
            + "--top-k 40 --top-p 0.95 --min-p 0.05 "
            + "--repeat-penalty 1.05 --seed -1 --jinja"
        #expect(invocation.displayCommand == expectedDisplayCommand)
    }

    @Test("rejects a relative model path")
    func rejectsRelativeModelPath() {
        var profile = makeProfile()
        profile.model.mainPath = "Models/model.gguf"

        #expect(
            throws: ServerInvocationError.modelPathMustBeAbsolute(
                "Models/model.gguf"
            )
        ) {
            _ = try ServerInvocationBuilder().makeServerInvocation(
                profile: profile,
                runtime: makeRuntime(supportedFlags: ["--model", "--host", "--port"])
            )
        }
    }

    @Test("rejects managed flags duplicated by Extra Arguments")
    func rejectsConflictingExtraArguments() {
        var profile = makeProfile()
        profile.extraArguments = ["--port", "9999"]

        #expect(
            throws: ServerInvocationError.conflictingExtraArgument("--port")
        ) {
            _ = try ServerInvocationBuilder().makeServerInvocation(
                profile: profile,
                runtime: makeRuntime(supportedFlags: [])
            )
        }
    }

    @Test("reports a typed flag unsupported by detected capabilities")
    func rejectsUnsupportedTypedFlag() {
        let profile = makeProfile()

        #expect(
            throws: ServerInvocationError.unsupportedFlag("--ctx-size")
        ) {
            _ = try ServerInvocationBuilder().makeServerInvocation(
                profile: profile,
                runtime: makeRuntime(
                    supportedFlags: ["--model", "--alias", "--host", "--port"]
                )
            )
        }
    }

    @Test("allows typed flags when capability detection is unknown")
    func allowsUnknownCapabilities() throws {
        let profile = makeProfile()
        var runtime = makeRuntime(supportedFlags: [])
        runtime.capabilities = RuntimeCapabilities(
            supportedFlags: [],
            rawHelpHash: "0000000000000000",
            supportsWebUI: false,
            supportsMetrics: false,
            supportsPropsEndpoint: false,
            detectedAt: .distantPast,
            detection: .unknown
        )

        let invocation = try ServerInvocationBuilder().makeServerInvocation(
            profile: profile,
            runtime: runtime
        )

        #expect(invocation.arguments.contains("--ctx-size"))
    }
}

private func makeRuntime(
    supportedFlags: Set<String>
) -> RuntimeInstallation {
    RuntimeInstallation(
        id: "custom:test",
        source: .custom,
        llamaURL: nil,
        serverURL: URL(filePath: "/Applications/Llama Runtime/llama-server"),
        versionOutput: "b1234",
        capabilities: RuntimeCapabilities(
            supportedFlags: supportedFlags,
            rawHelpHash: "1234567890abcdef",
            supportsWebUI: true,
            supportsMetrics: supportedFlags.contains("--metrics"),
            supportsPropsEndpoint: false,
            detectedAt: .distantPast,
            detection: .detected
        )
    )
}
