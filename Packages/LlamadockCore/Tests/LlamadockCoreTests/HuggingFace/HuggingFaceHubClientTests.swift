import Foundation
import Testing
@testable import LlamadockCore

@Suite("Hugging Face Hub client")
struct HuggingFaceHubClientTests {
    @Test("searches GGUF repositories with bounded parameters")
    func searchesRepositories() async throws {
        let client = RecordingHuggingFaceHTTPClient(
            responses: [
                HTTPResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        [
                          {
                            "id": "open/repo-GGUF",
                            "modelId": "open/repo-GGUF",
                            "downloads": 42,
                            "likes": 7,
                            "lastModified": "2026-07-29T08:49:33.123Z",
                            "gated": null,
                            "private": false,
                            "pipeline_tag": "text-generation",
                            "tags": ["gguf", "llama.cpp"]
                          },
                          {
                            "id": "gated/repo-GGUF",
                            "downloads": 12,
                            "likes": 2,
                            "gated": "manual",
                            "private": false,
                            "tags": ["gguf"]
                          }
                        ]
                        """.utf8
                    )
                )
            ]
        )
        let service = HuggingFaceHubClient(client: client)

        let repositories = try await service.searchModels(
            query: " tiny llama ",
            limit: 500,
            token: nil
        )

        #expect(repositories.count == 2)
        #expect(repositories[0].id == "open/repo-GGUF")
        #expect(repositories[0].downloads == 42)
        #expect(repositories[0].lastModified != nil)
        #expect(repositories[0].gated == .none)
        #expect(repositories[1].gated == .manual)
        #expect(repositories[1].gated.requiresAuthentication)

        let request = try #require(await client.requests().first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
            )
        )
        let queryItems = try #require(components.queryItems)
        #expect(queryItems.contains(URLQueryItem(name: "search", value: "tiny llama")))
        #expect(queryItems.contains(URLQueryItem(name: "filter", value: "gguf")))
        #expect(queryItems.contains(URLQueryItem(name: "sort", value: "downloads")))
        #expect(queryItems.contains(URLQueryItem(name: "direction", value: "-1")))
        #expect(queryItems.contains(URLQueryItem(name: "limit", value: "100")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == "LlamaDock"
        )
    }

    @Test("loads a recursive repository tree with optional bearer auth")
    func loadsRepositoryTree() async throws {
        let lfsOID = String(repeating: "a", count: 64)
        let client = RecordingHuggingFaceHTTPClient(
            responses: [
                HTTPResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        [
                          {
                            "type": "directory",
                            "path": "docs",
                            "size": 0,
                            "oid": "tree"
                          },
                          {
                            "type": "file",
                            "path": "weights/model.Q4_K_M.gguf",
                            "size": 100,
                            "oid": "git-oid",
                            "lfs": {
                              "oid": "\(lfsOID)",
                              "size": 123456,
                              "pointerSize": 133
                            }
                          }
                        ]
                        """.utf8
                    )
                )
            ]
        )
        let service = HuggingFaceHubClient(client: client)
        let reference = HuggingFaceRepositoryReference(
            repositoryID: "owner/repo",
            revision: "feature/test"
        )

        let files = try await service.repositoryFiles(
            reference: reference,
            token: "hf_secret"
        )

        #expect(files.count == 1)
        #expect(files[0].path == "weights/model.Q4_K_M.gguf")
        #expect(files[0].size == 123_456)
        #expect(files[0].expectedSHA256 == lfsOID)

        let request = try #require(await client.requests().first)
        #expect(
            request.url?.absoluteString
                == "https://huggingface.co/api/models/owner/repo/tree/feature%2Ftest?recursive=true&expand=false"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer hf_secret"
        )

        let resolveURL = try service.resolveURL(
            reference: reference,
            filePath: "weights/model Q4.gguf"
        )
        #expect(
            resolveURL.absoluteString
                == "https://huggingface.co/owner/repo/resolve/feature%2Ftest/weights/model%20Q4.gguf?download=true"
        )
    }

    @Test("maps authentication, access, missing, and rate limit failures")
    func mapsHTTPFailures() async {
        let reference = HuggingFaceRepositoryReference(
            repositoryID: "owner/repo"
        )
        let cases: [(Int, HuggingFaceHubError)] = [
            (401, .authenticationRequired),
            (403, .accessDenied),
            (404, .repositoryNotFound("owner/repo")),
            (429, .rateLimited),
        ]

        for (status, expected) in cases {
            let service = HuggingFaceHubClient(
                client: RecordingHuggingFaceHTTPClient(
                    responses: [
                        HTTPResponse(
                            statusCode: status,
                            data: Data()
                        )
                    ]
                )
            )
            await #expect(throws: expected) {
                try await service.repositoryFiles(
                    reference: reference,
                    token: nil
                )
            }
        }
    }

    @Test("follows same-origin tree pagination and rejects token exfiltration")
    func followsSafePagination() async throws {
        let service = HuggingFaceHubClient(
            client: RecordingHuggingFaceHTTPClient(
                responses: [
                    HTTPResponse(
                        statusCode: 200,
                        data: Data(
                            """
                            [
                              {
                                "type": "file",
                                "path": "first.gguf",
                                "size": 1
                              }
                            ]
                            """.utf8
                        ),
                        headers: [
                            "Link": #"<https://huggingface.co/api/models/owner/repo/tree/main?recursive=true&cursor=next>; rel="next""#,
                        ]
                    ),
                    HTTPResponse(
                        statusCode: 200,
                        data: Data(
                            """
                            [
                              {
                                "type": "file",
                                "path": "second.gguf",
                                "size": 2
                              }
                            ]
                            """.utf8
                        )
                    ),
                ]
            )
        )

        let files = try await service.repositoryFiles(
            reference: HuggingFaceRepositoryReference(
                repositoryID: "owner/repo"
            ),
            token: "hf_secret"
        )

        #expect(files.map(\.path) == ["first.gguf", "second.gguf"])

        let malicious = HuggingFaceHubClient(
            client: RecordingHuggingFaceHTTPClient(
                responses: [
                    HTTPResponse(
                        statusCode: 200,
                        data: Data("[]".utf8),
                        headers: [
                            "Link": #"<https://example.com/steal>; rel="next""#,
                        ]
                    )
                ]
            )
        )
        await #expect(
            throws: HuggingFaceHubError.invalidPayload(
                "The repository pagination link leaves huggingface.co."
            )
        ) {
            try await malicious.repositoryFiles(
                reference: HuggingFaceRepositoryReference(
                    repositoryID: "owner/repo"
                ),
                token: "hf_secret"
            )
        }
    }
}

private actor RecordingHuggingFaceHTTPClient: HTTPRequesting {
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
