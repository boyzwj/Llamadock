import Foundation

public enum LlamaServerBenchmarkError:
    Error,
    Equatable,
    Sendable
{
    case invalidEndpoint
    case invalidModel
    case invalidPromptTokens(Int)
    case invalidGenerationTokens(Int)
    case invalidConcurrency(Int)
    case unexpectedStatus(Int, message: String?)
    case malformedResponse
    case missingTimings
}

extension LlamaServerBenchmarkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The llama-server benchmark endpoint is invalid."
        case .invalidModel:
            "Choose a model before running the benchmark."
        case .invalidPromptTokens(let value):
            "Prompt token target \(value) is outside the supported range."
        case .invalidGenerationTokens(let value):
            "Generation token target \(value) is outside the supported range."
        case .invalidConcurrency(let value):
            "Concurrency \(value) is outside the supported range."
        case .unexpectedStatus(let status, let message):
            "llama-server returned HTTP \(status)"
                + (message.map { ": \($0)" } ?? ".")
        case .malformedResponse:
            "llama-server returned an invalid benchmark response."
        case .missingTimings:
            "This llama-server response did not include performance timings."
        }
    }
}

public struct LlamaServerBenchmarkMeasurement:
    Equatable,
    Sendable
{
    public let promptTokens: Int
    public let processedPromptTokens: Int
    public let cachedPromptTokens: Int
    public let generatedTokens: Int
    public let promptMilliseconds: Double
    public let promptTokensPerSecond: Double
    public let generationMilliseconds: Double
    public let generationTokensPerSecond: Double
    public let generationMillisecondsPerToken: Double

    public init(
        promptTokens: Int,
        processedPromptTokens: Int,
        cachedPromptTokens: Int,
        generatedTokens: Int,
        promptMilliseconds: Double,
        promptTokensPerSecond: Double,
        generationMilliseconds: Double,
        generationTokensPerSecond: Double,
        generationMillisecondsPerToken: Double
    ) {
        self.promptTokens = promptTokens
        self.processedPromptTokens = processedPromptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.generatedTokens = generatedTokens
        self.promptMilliseconds = promptMilliseconds
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generationMilliseconds = generationMilliseconds
        self.generationTokensPerSecond = generationTokensPerSecond
        self.generationMillisecondsPerToken =
            generationMillisecondsPerToken
    }
}

public struct LlamaServerBenchmarkTrial:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public let targetPromptTokens: Int
    public let concurrency: Int
    public let requestCount: Int
    public let promptTokens: Int
    public let processedPromptTokens: Int
    public let cachedPromptTokens: Int
    public let generatedTokens: Int
    public let wallMilliseconds: Double
    public let averagePromptTokensPerSecond: Double
    public let averageGenerationTokensPerSecond: Double
    public let averageGenerationMillisecondsPerToken: Double

    public init(
        id: UUID = UUID(),
        targetPromptTokens: Int,
        concurrency: Int,
        requestCount: Int,
        promptTokens: Int,
        processedPromptTokens: Int,
        cachedPromptTokens: Int,
        generatedTokens: Int,
        wallMilliseconds: Double,
        averagePromptTokensPerSecond: Double,
        averageGenerationTokensPerSecond: Double,
        averageGenerationMillisecondsPerToken: Double
    ) {
        self.id = id
        self.targetPromptTokens = targetPromptTokens
        self.concurrency = concurrency
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.processedPromptTokens = processedPromptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.generatedTokens = generatedTokens
        self.wallMilliseconds = wallMilliseconds
        self.averagePromptTokensPerSecond =
            averagePromptTokensPerSecond
        self.averageGenerationTokensPerSecond =
            averageGenerationTokensPerSecond
        self.averageGenerationMillisecondsPerToken =
            averageGenerationMillisecondsPerToken
    }

    public var outputTokensPerSecond: Double {
        guard wallMilliseconds > 0 else {
            return 0
        }
        return Double(generatedTokens) / (wallMilliseconds / 1_000)
    }

    public var totalTokensPerSecond: Double {
        guard wallMilliseconds > 0 else {
            return 0
        }
        return Double(promptTokens + generatedTokens)
            / (wallMilliseconds / 1_000)
    }

    public var requestsPerSecond: Double {
        guard wallMilliseconds > 0 else {
            return 0
        }
        return Double(requestCount) / (wallMilliseconds / 1_000)
    }
}

public struct LlamaServerBenchmarkRunner: Sendable {
    private let client: any HTTPRequesting

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient()
    ) {
        self.client = client
    }

    public func warmUp(
        baseURL: URL,
        model: String
    ) async throws {
        _ = try await request(
            baseURL: baseURL,
            model: model,
            targetPromptTokens: 64,
            generationTokens: 8,
            nonce: "warmup-\(UUID().uuidString)"
        )
    }

    public func runTrial(
        baseURL: URL,
        model: String,
        targetPromptTokens: Int,
        generationTokens: Int,
        concurrency: Int
    ) async throws -> LlamaServerBenchmarkTrial {
        try validate(
            baseURL: baseURL,
            model: model,
            targetPromptTokens: targetPromptTokens,
            generationTokens: generationTokens,
            concurrency: concurrency
        )
        try Task.checkCancellation()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let trialID = UUID().uuidString
        let measurements = try await withThrowingTaskGroup(
            of: LlamaServerBenchmarkMeasurement.self,
            returning: [LlamaServerBenchmarkMeasurement].self
        ) { group in
            for index in 0..<concurrency {
                group.addTask {
                    try await request(
                        baseURL: baseURL,
                        model: model,
                        targetPromptTokens: targetPromptTokens,
                        generationTokens: generationTokens,
                        nonce: "\(trialID)-\(index)"
                    )
                }
            }

            var values: [LlamaServerBenchmarkMeasurement] = []
            values.reserveCapacity(concurrency)
            for try await value in group {
                values.append(value)
            }
            return values
        }
        let wallMilliseconds = milliseconds(
            from: startedAt.duration(to: clock.now)
        )

        return Self.aggregate(
            measurements,
            targetPromptTokens: targetPromptTokens,
            concurrency: concurrency,
            wallMilliseconds: wallMilliseconds
        )
    }

    static func aggregate(
        _ measurements: [LlamaServerBenchmarkMeasurement],
        targetPromptTokens: Int,
        concurrency: Int,
        wallMilliseconds: Double
    ) -> LlamaServerBenchmarkTrial {
        LlamaServerBenchmarkTrial(
            targetPromptTokens: targetPromptTokens,
            concurrency: concurrency,
            requestCount: measurements.count,
            promptTokens: measurements.reduce(0) {
                $0 + $1.promptTokens
            },
            processedPromptTokens: measurements.reduce(0) {
                $0 + $1.processedPromptTokens
            },
            cachedPromptTokens: measurements.reduce(0) {
                $0 + $1.cachedPromptTokens
            },
            generatedTokens: measurements.reduce(0) {
                $0 + $1.generatedTokens
            },
            wallMilliseconds: wallMilliseconds,
            averagePromptTokensPerSecond: average(
                measurements.map(\.promptTokensPerSecond)
            ),
            averageGenerationTokensPerSecond: average(
                measurements.map(\.generationTokensPerSecond)
            ),
            averageGenerationMillisecondsPerToken: average(
                measurements.map(\.generationMillisecondsPerToken)
            )
        )
    }

    private func request(
        baseURL: URL,
        model: String,
        targetPromptTokens: Int,
        generationTokens: Int,
        nonce: String
    ) async throws -> LlamaServerBenchmarkMeasurement {
        guard
            let endpoint = URL(
                string: "v1/completions",
                relativeTo: baseURL
            )?.absoluteURL
        else {
            throw LlamaServerBenchmarkError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(
            CompletionRequest(
                model: model,
                prompt: Self.prompt(
                    targetTokens: targetPromptTokens,
                    nonce: nonce
                ),
                maxTokens: generationTokens
            )
        )

        let response = try await client.data(for: request)
        guard response.statusCode == 200 else {
            throw LlamaServerBenchmarkError.unexpectedStatus(
                response.statusCode,
                message: serverErrorMessage(from: response.data)
            )
        }

        let payload: CompletionResponse
        do {
            payload = try JSONDecoder().decode(
                CompletionResponse.self,
                from: response.data
            )
        } catch {
            throw LlamaServerBenchmarkError.malformedResponse
        }
        guard let timings = payload.timings else {
            throw LlamaServerBenchmarkError.missingTimings
        }

        let promptTokens = payload.usage?.promptTokens
            ?? timings.promptN + timings.cacheN
        let generatedTokens = payload.usage?.completionTokens
            ?? timings.predictedN
        return LlamaServerBenchmarkMeasurement(
            promptTokens: promptTokens,
            processedPromptTokens: timings.promptN,
            cachedPromptTokens: timings.cacheN,
            generatedTokens: generatedTokens,
            promptMilliseconds: timings.promptMilliseconds,
            promptTokensPerSecond: timings.promptTokensPerSecond,
            generationMilliseconds: timings.predictedMilliseconds,
            generationTokensPerSecond:
                timings.predictedTokensPerSecond,
            generationMillisecondsPerToken:
                timings.predictedMillisecondsPerToken
        )
    }

    private func validate(
        baseURL: URL,
        model: String,
        targetPromptTokens: Int,
        generationTokens: Int,
        concurrency: Int
    ) throws {
        guard
            baseURL.scheme == "http" || baseURL.scheme == "https",
            baseURL.host != nil
        else {
            throw LlamaServerBenchmarkError.invalidEndpoint
        }
        guard !model.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw LlamaServerBenchmarkError.invalidModel
        }
        guard (64...262_144).contains(targetPromptTokens) else {
            throw LlamaServerBenchmarkError.invalidPromptTokens(
                targetPromptTokens
            )
        }
        guard (1...4_096).contains(generationTokens) else {
            throw LlamaServerBenchmarkError.invalidGenerationTokens(
                generationTokens
            )
        }
        guard (1...16).contains(concurrency) else {
            throw LlamaServerBenchmarkError.invalidConcurrency(
                concurrency
            )
        }
    }

    private static func prompt(
        targetTokens: Int,
        nonce: String
    ) -> String {
        let header = """
            Synthetic local inference throughput benchmark \(nonce).
            Continue producing ordinary text until the requested output \
            limit is reached. Prompt payload:
            """
        let token = " benchmark"
        let payloadCount = max(targetTokens - 48, 1)
        return header + String(repeating: token, count: payloadCount)
    }

    private func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func average(_ values: [Double]) -> Double {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else {
            return 0
        }
        return finite.reduce(0, +) / Double(finite.count)
    }
}

private struct CompletionRequest: Encodable {
    let model: String
    let prompt: String
    let maxTokens: Int
    let temperature = 0.0
    let stream = false
    let cachePrompt = false
    let ignoreEndOfSequence = true

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case maxTokens = "max_tokens"
        case temperature
        case stream
        case cachePrompt = "cache_prompt"
        case ignoreEndOfSequence = "ignore_eos"
    }
}

private struct CompletionResponse: Decodable {
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct Timings: Decodable {
        let cacheN: Int
        let promptN: Int
        let promptMilliseconds: Double
        let promptTokensPerSecond: Double
        let predictedN: Int
        let predictedMilliseconds: Double
        let predictedMillisecondsPerToken: Double
        let predictedTokensPerSecond: Double

        enum CodingKeys: String, CodingKey {
            case cacheN = "cache_n"
            case promptN = "prompt_n"
            case promptMilliseconds = "prompt_ms"
            case promptTokensPerSecond = "prompt_per_second"
            case predictedN = "predicted_n"
            case predictedMilliseconds = "predicted_ms"
            case predictedMillisecondsPerToken =
                "predicted_per_token_ms"
            case predictedTokensPerSecond =
                "predicted_per_second"
        }
    }

    let usage: Usage?
    let timings: Timings?
}

private struct ServerErrorPayload: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: Detail?
}

private func serverErrorMessage(from data: Data) -> String? {
    try? JSONDecoder().decode(
        ServerErrorPayload.self,
        from: data
    ).error?.message
}
