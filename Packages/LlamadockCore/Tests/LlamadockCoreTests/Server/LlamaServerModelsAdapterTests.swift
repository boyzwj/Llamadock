import Foundation
import Testing
@testable import LlamadockCore

@Suite("llama-server models adapter")
struct LlamaServerModelsAdapterTests {
    @Test("parses router model states")
    func parsesStates() async throws {
        let client = ModelsHTTPClient(
            response: HTTPResponse(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "data": [
                        {
                          "id": "coder",
                          "path": "/Models/Coder.gguf",
                          "status": { "value": "loaded" }
                        },
                        {
                          "id": "vision",
                          "status": {
                            "value": "unloaded",
                            "failed": true,
                            "exit_code": 1
                          }
                        }
                      ]
                    }
                    """.utf8
                )
            )
        )

        let models = try await LlamaServerModelsAdapter(
            client: client
        ).models(baseURL: URL(string: "http://127.0.0.1:8080")!)

        #expect(
            models == [
                LlamaServerModel(
                    id: "coder",
                    path: "/Models/Coder.gguf",
                    state: .loaded
                ),
                LlamaServerModel(
                    id: "vision",
                    path: nil,
                    state: .failed
                ),
            ]
        )
    }
}

private struct ModelsHTTPClient: HTTPRequesting {
    let response: HTTPResponse

    func data(
        for request: URLRequest
    ) async throws -> HTTPResponse {
        response
    }
}
