import Foundation
import Testing
@testable import LlamadockCore

@Suite("llama-server health adapter")
struct LlamaServerHealthAdapterTests {
    @Test("recognizes a ready health response")
    func recognizesReady() async {
        let client = QueueHTTPClient(
            responses: [
                .success(
                    HTTPResponse(
                        statusCode: 200,
                        data: Data(#"{"status":"ok"}"#.utf8)
                    )
                )
            ]
        )
        let adapter = LlamaServerHealthAdapter(client: client)

        let result = await adapter.check(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )

        #expect(result == .ready)
        #expect(
            await client.requestedURLs()
                == [URL(string: "http://127.0.0.1:8080/health")!]
        )
    }

    @Test("recognizes a loading response even when HTTP is 503")
    func recognizesLoading() async {
        let client = QueueHTTPClient(
            responses: [
                .success(
                    HTTPResponse(
                        statusCode: 503,
                        data: Data(#"{"status":"loading model"}"#.utf8)
                    )
                )
            ]
        )
        let adapter = LlamaServerHealthAdapter(client: client)

        let result = await adapter.check(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )

        #expect(result == .starting(detail: "loading model"))
    }

    @Test("marks HTTP 200 with an unknown payload as degraded")
    func degradesUnknownPayload() async {
        let client = QueueHTTPClient(
            responses: [
                .success(
                    HTTPResponse(
                        statusCode: 200,
                        data: Data(#"{"unexpected":true}"#.utf8)
                    )
                )
            ]
        )
        let adapter = LlamaServerHealthAdapter(client: client)

        let result = await adapter.check(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )

        #expect(result == .degraded(reason: "HTTP 200 health payload was not recognized."))
    }

    @Test("reports transport failures as unavailable")
    func reportsTransportFailure() async {
        let client = QueueHTTPClient(
            responses: [.failure(FakeHTTPError.offline)]
        )
        let adapter = LlamaServerHealthAdapter(client: client)

        let result = await adapter.check(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )

        guard case .unavailable(let reason) = result else {
            Issue.record("Expected unavailable, got \(result)")
            return
        }
        #expect(reason.contains("offline"))
    }
}

private enum FakeHTTPError: Error {
    case offline
}

private actor QueueHTTPClient: HTTPRequesting {
    private var responses: [Result<HTTPResponse, Error>]
    private var urls: [URL] = []

    init(responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        if let url = request.url {
            urls.append(url)
        }
        return try responses.removeFirst().get()
    }

    func requestedURLs() -> [URL] {
        urls
    }
}
