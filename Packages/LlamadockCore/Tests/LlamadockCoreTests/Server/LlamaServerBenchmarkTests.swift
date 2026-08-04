import Foundation
import Testing
@testable import LlamadockCore

@Suite("llama-server benchmark")
struct LlamaServerBenchmarkTests {
    @Test("sends routed completion requests and aggregates a batch")
    func runsConcurrentTrial() async throws {
        let client = BenchmarkHTTPClient(
            response: HTTPResponse(
                statusCode: 200,
                data: benchmarkResponseData()
            )
        )
        let runner = LlamaServerBenchmarkRunner(client: client)

        let trial = try await runner.runTrial(
            baseURL: URL(string: "http://127.0.0.1:39281")!,
            model: "qwen-coder",
            targetPromptTokens: 1_024,
            generationTokens: 128,
            concurrency: 2
        )

        #expect(trial.targetPromptTokens == 1_024)
        #expect(trial.concurrency == 2)
        #expect(trial.requestCount == 2)
        #expect(trial.promptTokens == 2_048)
        #expect(trial.processedPromptTokens == 1_984)
        #expect(trial.cachedPromptTokens == 64)
        #expect(trial.generatedTokens == 256)
        #expect(trial.averagePromptTokensPerSecond == 2_480)
        #expect(trial.averageGenerationTokensPerSecond == 64)
        #expect(trial.averageGenerationMillisecondsPerToken == 15.625)
        #expect(trial.wallMilliseconds > 0)

        let requests = await client.requests()
        #expect(requests.count == 2)
        #expect(
            requests.allSatisfy {
                $0.url?.absoluteString
                    == "http://127.0.0.1:39281/v1/completions"
            }
        )
        let body = try #require(requests.first?.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        #expect(object["model"] as? String == "qwen-coder")
        #expect(object["max_tokens"] as? Int == 128)
        #expect(object["cache_prompt"] as? Bool == false)
        #expect(object["ignore_eos"] as? Bool == true)
    }

    @Test("uses server timings for deterministic aggregation")
    func aggregatesMeasurements() {
        let measurement = LlamaServerBenchmarkMeasurement(
            promptTokens: 1_000,
            processedPromptTokens: 900,
            cachedPromptTokens: 100,
            generatedTokens: 100,
            promptMilliseconds: 500,
            promptTokensPerSecond: 1_800,
            generationMilliseconds: 2_000,
            generationTokensPerSecond: 50,
            generationMillisecondsPerToken: 20
        )

        let trial = LlamaServerBenchmarkRunner.aggregate(
            [measurement, measurement],
            targetPromptTokens: 1_024,
            concurrency: 2,
            wallMilliseconds: 2_500
        )

        #expect(trial.outputTokensPerSecond == 80)
        #expect(trial.totalTokensPerSecond == 880)
        #expect(trial.requestsPerSecond == 0.8)
    }

    @Test("surfaces llama-server API errors")
    func surfacesServerError() async {
        let client = BenchmarkHTTPClient(
            response: HTTPResponse(
                statusCode: 400,
                data: Data(
                    """
                    {"error":{"message":"model is not available"}}
                    """.utf8
                )
            )
        )
        let runner = LlamaServerBenchmarkRunner(client: client)

        await #expect(
            throws: LlamaServerBenchmarkError.unexpectedStatus(
                400,
                message: "model is not available"
            )
        ) {
            _ = try await runner.runTrial(
                baseURL: URL(string: "http://127.0.0.1:39281")!,
                model: "missing",
                targetPromptTokens: 1_024,
                generationTokens: 64,
                concurrency: 1
            )
        }
    }
}

private actor BenchmarkHTTPClient: HTTPRequesting {
    private let response: HTTPResponse
    private var capturedRequests: [URLRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        capturedRequests.append(request)
        return response
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}

private func benchmarkResponseData() -> Data {
    Data(
        """
        {
          "usage": {
            "prompt_tokens": 1024,
            "completion_tokens": 128,
            "total_tokens": 1152
          },
          "timings": {
            "cache_n": 32,
            "prompt_n": 992,
            "prompt_ms": 400,
            "prompt_per_token_ms": 0.4032258065,
            "prompt_per_second": 2480,
            "predicted_n": 128,
            "predicted_ms": 2000,
            "predicted_per_token_ms": 15.625,
            "predicted_per_second": 64
          }
        }
        """.utf8
    )
}
