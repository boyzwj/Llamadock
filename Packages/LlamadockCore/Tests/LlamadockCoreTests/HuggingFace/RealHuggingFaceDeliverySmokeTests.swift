import Foundation
import Testing
@testable import LlamadockCore

@Suite("Real Hugging Face delivery smoke")
struct RealHuggingFaceDeliverySmokeTests {
    @Test("downloads, imports, profiles, starts, and completes")
    func deliversPublicModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["LLAMADOCK_HF_DELIVERY_SMOKE"] == "1",
            let serverPath = environment[
                "LLAMADOCK_HF_DELIVERY_SERVER"
            ],
            let portValue = environment[
                "LLAMADOCK_HF_DELIVERY_PORT"
            ],
            let port = UInt16(portValue)
        else {
            return
        }

        let root = FileManager.default.temporaryDirectory.appending(
            path: "LlamadockHFDelivery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let manager = ModelDownloadManager(
            directories: directories,
            tokenStore: EmptyHuggingFaceTokenStore()
        )
        let expectedSize: Int64 = 19_077_344
        let expectedSHA256 =
            "6151b1929d7f5aa3385d9ddef3393e55587c0a55de661562322bc51dfda93a04"
        let id = try await manager.enqueue(
            ModelDownloadRequest(
                reference: HuggingFaceRepositoryReference(
                    repositoryID: "ggml-org/tiny-llamas"
                ),
                displayName: "stories15M-q4_0.gguf",
                quantization: "Q4_0",
                files: [
                    ModelDownloadRequestFile(
                        artifactID: "main:stories15m-q4_0.gguf",
                        artifactDisplayName:
                            "stories15M-q4_0.gguf",
                        role: .main,
                        repositoryPath:
                            "stories15M-q4_0.gguf",
                        expectedSize: expectedSize,
                        expectedSHA256: expectedSHA256
                    ),
                ]
            )
        )
        let job = try await waitForCompletion(
            id: id,
            manager: manager
        )
        #expect(
            job.files.allSatisfy {
                $0.isVerified
            }
        )

        var profile = try ModelDownloadProfileFactory()
            .makeProfile(
                for: job,
                modelsRoot: directories.models,
                runtimeID: "real-hf-delivery"
            )
        profile.server.port = port
        let metadata = try GGUFMetadataReader().read(
            from: URL(filePath: profile.model.mainPath)
        )
        #expect(metadata.architecture == "llama")
        #expect(Int64(metadata.fileSize) == expectedSize)

        let serverURL = URL(
            filePath: serverPath,
            directoryHint: .notDirectory
        )
        let help = try await FoundationProcessRunner().run(
            ProcessInvocation(
                executableURL: serverURL,
                arguments: ["--help"]
            ),
            timeout: .seconds(30)
        )
        let runtime = RuntimeInstallation(
            id: "real-hf-delivery",
            source: .custom,
            llamaURL: nil,
            serverURL: serverURL,
            versionOutput: "real Hugging Face delivery smoke",
            capabilities: RuntimeCapabilitiesParser().parse(
                [help.standardOutput, help.standardError]
                    .joined(separator: "\n")
            )
        )
        let invocation = try ServerInvocationBuilder()
            .makeServerInvocation(
                profile: profile,
                runtime: runtime
            )
        let controller = ServerProcessController()

        do {
            try await controller.start(
                profileID: profile.id,
                runtimeID: runtime.id,
                invocation: invocation,
                host: profile.server.host,
                port: profile.server.port,
                readinessTimeout: .seconds(60)
            )
            #expect(await controller.snapshot().state == .ready)
            try await expectCompletion(port: port)
        } catch {
            await controller.stop()
            throw error
        }

        await controller.stop()
        #expect(await controller.snapshot().state == .stopped)
    }

    private func waitForCompletion(
        id: UUID,
        manager: ModelDownloadManager
    ) async throws -> ModelDownloadJob {
        for _ in 0..<1_200 {
            if
                let job = await manager.snapshot().jobs.first(
                    where: { $0.id == id }
                )
            {
                if job.state == .completed {
                    return job
                }
                if job.state == .failed {
                    throw RealHuggingFaceDeliveryError.failed(
                        job.error ?? "unknown download failure"
                    )
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RealHuggingFaceDeliveryError.failed(
            "download timed out"
        )
    }

    private func expectCompletion(
        port: UInt16
    ) async throws {
        var request = URLRequest(
            url: URL(
                string:
                    "http://127.0.0.1:\(port)/v1/completions"
            )!
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "stories15M",
                "prompt": "Once upon a time",
                "max_tokens": 1,
                "temperature": 0,
            ]
        )
        let (data, response) = try await URLSession.shared.data(
            for: request
        )
        guard
            let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            let document = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let choices = document["choices"] as? [[String: Any]],
            !choices.isEmpty
        else {
            throw RealHuggingFaceDeliveryError.failed(
                "OpenAI-compatible completion did not return choices"
            )
        }
    }
}

private enum RealHuggingFaceDeliveryError:
    Error,
    Equatable
{
    case failed(String)
}

private struct EmptyHuggingFaceTokenStore:
    HuggingFaceTokenStoring,
    Sendable
{
    func token() throws -> String? {
        nil
    }

    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
}
