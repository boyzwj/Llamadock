import Foundation
import Testing
@testable import LlamadockCore

@Suite("Models preset builder")
struct ModelsPresetBuilderTests {
    @Test("builds a readable multi-model INI document")
    func buildsPresetDocument() throws {
        var first = makeProfile()
        first.router = RouterModelOptions(
            identifier: "qwen-coder",
            loadOnStartup: true,
            stopTimeout: 15
        )
        first.server.contextSize = nil
        first.server.cacheTypeK = nil
        first.server.cacheTypeV = nil
        var second = makeProfile(id: UUID())
        second.name = "Embedding"
        second.model.mainPath = "/Models/Embedding.gguf"
        second.router = RouterModelOptions(
            identifier: "embedding",
            loadOnStartup: false
        )
        second.server.contextSize = 8_192
        second.server.systemPrompt = nil
        second.sampling = SamplingOptions()
        second.extraArguments = []

        let document = try ModelsPresetBuilder().makeDocument(
            profiles: [first, second],
            runtime: makeRouterRuntime()
        )

        #expect(document.profileIDs == [first.id, second.id])
        #expect(
            document.contents.contains(
                """
                [*]
                ctx-size = 32768
                cache-type-k = q8_0
                cache-type-v = q8_0
                n-gpu-layers = auto
                kv-offload = true
                fit = on
                fit-target = 1024
                fit-ctx = 4096
                flash-attn = auto
                threads = -1
                parallel = -1
                batch-size = 2048
                ubatch-size = 512
                """
            )
        )
        #expect(
            document.contents.contains(
                """
                [qwen-coder]
                model = /Models/My Model.gguf
                """
            )
        )
        #expect(
            document.contents.contains(
                """
                load-on-startup = true
                stop-timeout = 15
                jinja = true
                """
            )
        )
        #expect(
            document.contents.contains(
                """
                [embedding]
                model = /Models/Embedding.gguf
                ctx-size = 8192
                """
            )
        )
        #expect(!document.contents.contains("host ="))
        #expect(!document.contents.contains("port ="))
        #expect(!document.contents.contains("alias ="))
    }

    @Test("builds the router process invocation")
    func buildsRouterInvocation() throws {
        let runtime = makeRouterRuntime()
        let invocation = try ModelsPresetBuilder().makeInvocation(
            presetURL: URL(filePath: "/Config/models.ini"),
            options: RouterServerOptions(
                host: "0.0.0.0",
                port: 39_281,
                maximumLoadedModels: 2,
                modelsAutoload: false
            ),
            runtime: runtime
        )

        #expect(
            invocation.arguments == [
                "--host", "0.0.0.0",
                "--port", "39281",
                "--models-preset", "/Config/models.ini",
                "--models-max", "2",
                "--no-models-autoload",
            ]
        )
    }

    @Test("rejects duplicate router identifiers")
    func rejectsDuplicateIdentifiers() {
        var first = makeProfile()
        first.router.identifier = "duplicate"
        var second = makeProfile(id: UUID())
        second.router.identifier = "duplicate"

        #expect(
            throws: ModelsPresetError.duplicateIdentifier("duplicate")
        ) {
            _ = try ModelsPresetBuilder().makeDocument(
                profiles: [first, second],
                runtime: makeRouterRuntime()
            )
        }
    }

    @Test("ignores disabled model settings")
    func ignoresDisabledProfiles() {
        var profile = makeProfile()
        profile.router.isEnabled = false

        #expect(throws: ModelsPresetError.noEnabledModels) {
            _ = try ModelsPresetBuilder().makeDocument(
                profiles: [profile],
                runtime: makeRouterRuntime()
            )
        }
    }

    @Test("keeps negative numeric extra argument values")
    func keepsNegativeNumericExtraArgumentValues() throws {
        var profile = makeProfile()
        profile.sampling.seed = nil
        profile.extraArguments = ["--seed", "-2"]

        let document = try ModelsPresetBuilder().makeDocument(
            profiles: [profile],
            runtime: makeRouterRuntime()
        )

        #expect(document.contents.contains("seed = -2"))
        #expect(!document.contents.contains("-2 = true"))
    }

    @Test("writes the documented negative KV offload flag")
    func writesNegativeKVOffloadFlag() throws {
        var globalOptions = GlobalModelOptions()
        globalOptions.kvOffload = false

        let document = try ModelsPresetBuilder().makeDocument(
            profiles: [makeProfile()],
            globalOptions: globalOptions,
            runtime: makeRouterRuntime()
        )

        #expect(document.contents.contains("no-kv-offload = true"))
        #expect(!document.contents.contains("kv-offload = false"))
    }
}

private func makeRouterRuntime() -> RuntimeInstallation {
    RuntimeInstallation(
        id: "custom:router",
        source: .custom,
        llamaURL: nil,
        serverURL: URL(filePath: "/Runtime/llama-server"),
        versionOutput: "b9999",
        capabilities: RuntimeCapabilities(
            supportedFlags: [
                "--model",
                "--host",
                "--port",
                "--models-preset",
                "--models-max",
                "--models-autoload",
                "--no-models-autoload",
                "--ctx-size",
                "--n-gpu-layers",
                "--threads",
                "--parallel",
                "--batch-size",
                "--ubatch-size",
                "--flash-attn",
                "--cache-type-k",
                "--cache-type-v",
                "--kv-offload",
                "--no-kv-offload",
                "--fit",
                "--fit-target",
                "--fit-ctx",
                "--system-prompt",
                "--temp",
                "--top-k",
                "--top-p",
                "--min-p",
                "--repeat-penalty",
                "--seed",
                "--jinja",
            ],
            rawHelpHash: "router",
            supportsWebUI: true,
            supportsMetrics: false,
            supportsPropsEndpoint: false,
            detectedAt: .distantPast,
            detection: .detected
        )
    )
}
