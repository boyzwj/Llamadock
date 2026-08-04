import Foundation
import Testing
@testable import LlamadockCore

@Suite("ModelScope Hub client")
struct ModelScopeHubClientTests {
    @Test("searches GGUF repositories with official OpenAPI parameters")
    func searchesRepositories() async throws {
        let client = RecordingModelScopeHTTPClient(
            responses: [
                HTTPResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        {
                          "success": true,
                          "data": {
                            "models": [
                              {
                                "id": "owner/model-GGUF",
                                "downloads": 42,
                                "likes": 7,
                                "last_modified": "2026-07-29T08:49:33Z",
                                "private": false,
                                "gated": false,
                                "tasks": ["text-generation"],
                                "tags": ["library:gguf"]
                              }
                            ],
                            "total_count": 1
                          }
                        }
                        """.utf8
                    )
                )
            ]
        )
        let service = ModelScopeHubClient(client: client)

        let repositories = try await service.searchModels(
            query: " Qwen ",
            limit: 500
        )

        #expect(repositories.count == 1)
        #expect(repositories[0].id == "owner/model-GGUF")
        #expect(repositories[0].downloads == 42)
        #expect(repositories[0].likes == 7)
        #expect(repositories[0].pipelineTag == "text-generation")
        #expect(repositories[0].lastModified != nil)

        let request = try #require(await client.requests().first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
            )
        )
        let queryItems = try #require(components.queryItems)
        #expect(components.path == "/openapi/v1/models")
        #expect(queryItems.contains(URLQueryItem(name: "search", value: "Qwen")))
        #expect(queryItems.contains(URLQueryItem(name: "sort", value: "downloads")))
        #expect(queryItems.contains(URLQueryItem(name: "page_size", value: "50")))
        #expect(queryItems.contains(URLQueryItem(name: "filter.library", value: "gguf")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "LlamaDock")
    }

    @Test("loads the recursive legacy file tree and maps SHA-256")
    func loadsRepositoryTree() async throws {
        let sha256 = String(repeating: "a", count: 64)
        let client = RecordingModelScopeHTTPClient(
            responses: [
                HTTPResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        {
                          "Code": 200,
                          "Data": {
                            "Files": [
                              {
                                "Type": "tree",
                                "Path": "weights",
                                "Size": 0,
                                "Revision": "tree-id",
                                "Sha256": ""
                              },
                              {
                                "Type": "blob",
                                "Path": "weights/model Q4.gguf",
                                "Size": 123456,
                                "Revision": "commit-id",
                                "Sha256": "\(sha256)"
                              }
                            ]
                          },
                          "Message": "success"
                        }
                        """.utf8
                    )
                )
            ]
        )
        let service = ModelScopeHubClient(client: client)
        let reference = HuggingFaceRepositoryReference(
            repositoryID: "owner/repo",
            revision: "master"
        )

        let files = try await service.repositoryFiles(
            reference: reference
        )

        #expect(files.count == 1)
        #expect(files[0].path == "weights/model Q4.gguf")
        #expect(files[0].size == 123_456)
        #expect(files[0].gitOID == "commit-id")
        #expect(files[0].expectedSHA256 == sha256)

        let request = try #require(await client.requests().first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
            )
        )
        #expect(
            components.path
                == "/api/v1/models/owner/repo/repo/files"
        )
        #expect(
            components.queryItems?.contains(
                URLQueryItem(name: "Revision", value: "master")
            ) == true
        )
        #expect(
            components.queryItems?.contains(
                URLQueryItem(name: "Recursive", value: "true")
            ) == true
        )

        let downloadURL = try service.resolveURL(
            reference: reference,
            filePath: "weights/model Q4.gguf"
        )
        let downloadComponents = try #require(
            URLComponents(
                url: downloadURL,
                resolvingAgainstBaseURL: false
            )
        )
        #expect(
            downloadComponents.path
                == "/api/v1/models/owner/repo/repo"
        )
        #expect(
            downloadComponents.queryItems?.contains(
                URLQueryItem(
                    name: "FilePath",
                    value: "weights/model Q4.gguf"
                )
            ) == true
        )
    }

    @Test("rejects unsafe repository, revision, and file paths")
    func rejectsUnsafeInputs() async {
        let service = ModelScopeHubClient(
            client: RecordingModelScopeHTTPClient(responses: [])
        )

        await #expect(throws: ModelScopeHubError.invalidRepositoryID("owner/../repo")) {
            try await service.repositoryFiles(
                reference: HuggingFaceRepositoryReference(
                    repositoryID: "owner/../repo"
                )
            )
        }
        #expect(throws: ModelScopeHubError.invalidRevision("..")) {
            try service.resolveURL(
                reference: HuggingFaceRepositoryReference(
                    repositoryID: "owner/repo",
                    revision: ".."
                ),
                filePath: "model.gguf"
            )
        }
        #expect(throws: ModelScopeHubError.unsafeFilePath("../model.gguf")) {
            try service.resolveURL(
                reference: HuggingFaceRepositoryReference(
                    repositoryID: "owner/repo",
                    revision: "master"
                ),
                filePath: "../model.gguf"
            )
        }
    }
}

private actor RecordingModelScopeHTTPClient: HTTPRequesting {
    private var pendingResponses: [HTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        pendingResponses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> HTTPResponse {
        recordedRequests.append(request)
        return pendingResponses.removeFirst()
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
