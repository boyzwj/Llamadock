import Foundation
import Testing
@testable import LlamadockCore

@Suite("GitHub latest runtime release")
struct GitHubLatestRuntimeReleaseTests {
    @Test("parses a llama.cpp build tag")
    func parsesBuildTag() throws {
        #expect(
            try LlamaBuildTag(parsing: "b10176")
                == LlamaBuildTag(tag: "b10176", build: 10_176)
        )
        #expect(throws: RuntimeReleaseError.invalidTag("v10176")) {
            try LlamaBuildTag(parsing: "v10176")
        }
        #expect(throws: RuntimeReleaseError.invalidTag("b0")) {
            try LlamaBuildTag(parsing: "b0")
        }
        #expect(
            LlamaBuildTag(
                parsingVersionOutput: """
                    version: 10176 (f5b9bd39b)
                    built for Darwin arm64
                    """
            ) == LlamaBuildTag(
                tag: "b10176",
                build: 10_176
            )
        )
        #expect(
            LlamaBuildTag(
                parsingVersionOutput: "llama.cpp build 10176"
            ) == nil
        )
    }

    @Test("selects the official macOS arm64 archive")
    func selectsAppleSiliconArchive() throws {
        let selector = GitHubRuntimeAssetSelector()
        let selected = try selector.selectMacOSAppleSiliconAsset(
            from: [
                makeAsset(name: "llama-b10176-bin-ubuntu-x64.tar.gz"),
                makeAsset(name: "llama-b10176-bin-macos-x64.tar.gz"),
                makeAsset(name: "llama-b10176-bin-macos-arm64.zip"),
                makeAsset(name: "llama-b10176-bin-macos-arm64.tar.gz"),
                makeAsset(name: "llama-b10176-bin-macos-arm64.tar.gz.sha256"),
            ]
        )

        #expect(
            selected.name
                == "llama-b10176-bin-macos-arm64.tar.gz"
        )
    }

    @Test("fetches latest with required headers and caches the ETag")
    func fetchesAndCaches() async throws {
        let responseData = makeReleaseJSON()
        let client = RecordingHTTPClient(
            responses: [
                .success(
                    HTTPResponse(
                        statusCode: 200,
                        data: responseData,
                        headers: ["ETag": #""release-b10176""#]
                    )
                )
            ]
        )
        let cache = InMemoryRuntimeReleaseCache()
        let service = GitHubLatestRuntimeReleaseClient(
            client: client,
            cache: cache
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let check = try await service.checkLatest(now: now)

        #expect(check.source == .network)
        #expect(check.warning == nil)
        #expect(check.release.build == 10_176)
        #expect(
            check.release.asset.name
                == "llama-b10176-bin-macos-arm64.tar.gz"
        )
        #expect(check.fetchedAt == now)

        let request = try #require(await client.requests().first)
        #expect(
            request.url?.absoluteString
                == "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
        )
        #expect(request.httpMethod == "GET")
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/vnd.github+json"
        )
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == "LlamaDock"
        )
        #expect(
            request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
                == "2022-11-28"
        )

        let cached = try #require(await cache.load())
        #expect(cached.etag == #""release-b10176""#)
        #expect(cached.fetchedAt == now)
        #expect(cached.release == check.release)
    }

    @Test("uses a validated cache after a 304 response")
    func handlesNotModified() async throws {
        let cached = makeCachedRelease()
        let cache = InMemoryRuntimeReleaseCache(entry: cached)
        let client = RecordingHTTPClient(
            responses: [
                .success(
                    HTTPResponse(statusCode: 304, data: Data())
                )
            ]
        )
        let service = GitHubLatestRuntimeReleaseClient(
            client: client,
            cache: cache
        )

        let check = try await service.checkLatest()

        #expect(check.source == .notModifiedCache)
        #expect(check.release == cached.release)
        #expect(check.fetchedAt == cached.fetchedAt)
        #expect(check.warning == nil)
        #expect(
            await client.requests().first?
                .value(forHTTPHeaderField: "If-None-Match")
                == cached.etag
        )
    }

    @Test("returns stale validated cache with a visible offline warning")
    func fallsBackOffline() async throws {
        let cached = makeCachedRelease()
        let service = GitHubLatestRuntimeReleaseClient(
            client: RecordingHTTPClient(
                responses: [.failure(FakeReleaseHTTPError.offline)]
            ),
            cache: InMemoryRuntimeReleaseCache(entry: cached)
        )

        let check = try await service.checkLatest()

        #expect(check.source == .staleCache)
        #expect(check.release == cached.release)
        #expect(check.warning?.contains("offline") == true)
    }

    @Test("does not hide an HTTP failure when no cache exists")
    func reportsHTTPFailureWithoutCache() async {
        let service = GitHubLatestRuntimeReleaseClient(
            client: RecordingHTTPClient(
                responses: [
                    .success(
                        HTTPResponse(
                            statusCode: 403,
                            data: Data(#"{"message":"rate limit"}"#.utf8)
                        )
                    )
                ]
            ),
            cache: InMemoryRuntimeReleaseCache()
        )

        await #expect(
            throws: RuntimeReleaseError.httpStatus(
                403,
                message: "rate limit"
            )
        ) {
            try await service.checkLatest()
        }
    }

    @Test("persists a readable release cache atomically")
    func persistsReleaseCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockReleaseCacheTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(
            path: "github/latest-release.json",
            directoryHint: .notDirectory
        )
        let expected = makeCachedRelease()

        let firstCache = JSONRuntimeReleaseCache(fileURL: fileURL)
        try await firstCache.save(expected)

        let rawJSON = try String(
            contentsOf: fileURL,
            encoding: .utf8
        )
        #expect(rawJSON.contains(#""schemaVersion" : 1"#))
        #expect(rawJSON.contains(#""etag" : "\"release-b10175\"""#))

        let secondCache = JSONRuntimeReleaseCache(fileURL: fileURL)
        #expect(try await secondCache.load() == expected)

        let siblingNames = try FileManager.default
            .contentsOfDirectory(
                atPath: fileURL.deletingLastPathComponent().path
            )
        #expect(siblingNames == ["latest-release.json"])
    }

    private func makeAsset(
        name: String
    ) -> GitHubRuntimeReleaseAsset {
        GitHubRuntimeReleaseAsset(
            id: 42,
            name: name,
            downloadURL: URL(
                string: "https://github.com/ggml-org/llama.cpp/releases/download/b10176/\(name)"
            )!,
            size: 10_925_555,
            contentType: "application/gzip",
            digest: nil
        )
    }

    private func makeReleaseJSON() -> Data {
        Data(
            """
            {
              "tag_name": "b10176",
              "published_at": "2026-07-29T08:49:33Z",
              "assets": [
                {
                  "id": 1,
                  "name": "llama-b10176-bin-ubuntu-x64.tar.gz",
                  "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b10176/ubuntu.tar.gz",
                  "size": 123,
                  "content_type": "application/gzip",
                  "digest": null
                },
                {
                  "id": 2,
                  "name": "llama-b10176-bin-macos-arm64.tar.gz",
                  "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b10176/llama-b10176-bin-macos-arm64.tar.gz",
                  "size": 10925555,
                  "content_type": "application/gzip",
                  "digest": "sha256:4cc6d269c28126c2c9f946601f74f3ceab07f785b8a61d9d795f314937993775"
                }
              ]
            }
            """.utf8
        )
    }

    private func makeCachedRelease() -> CachedRuntimeRelease {
        CachedRuntimeRelease(
            release: ManagedRuntimeRelease(
                buildTag: LlamaBuildTag(
                    tag: "b10175",
                    build: 10_175
                ),
                publishedAt: Date(timeIntervalSince1970: 1_799_000_000),
                asset: makeAsset(
                    name: "llama-b10175-bin-macos-arm64.tar.gz"
                )
            ),
            etag: #""release-b10175""#,
            fetchedAt: Date(timeIntervalSince1970: 1_799_000_100)
        )
    }
}

private enum FakeReleaseHTTPError: Error {
    case offline
}

private actor RecordingHTTPClient: HTTPRequesting {
    private var responses: [Result<HTTPResponse, Error>]
    private var recordedRequests: [URLRequest] = []

    init(responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        return try responses.removeFirst().get()
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor InMemoryRuntimeReleaseCache: RuntimeReleaseCaching {
    private var entry: CachedRuntimeRelease?

    init(entry: CachedRuntimeRelease? = nil) {
        self.entry = entry
    }

    func load() -> CachedRuntimeRelease? {
        entry
    }

    func save(_ entry: CachedRuntimeRelease) {
        self.entry = entry
    }
}
