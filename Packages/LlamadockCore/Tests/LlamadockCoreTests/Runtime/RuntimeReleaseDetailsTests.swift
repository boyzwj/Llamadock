import Foundation
import Testing
@testable import LlamadockCore

@Suite("Runtime release details")
struct RuntimeReleaseDetailsTests {
    @Test("fetches changelog and publication time by build tag")
    func fetchesDetails() async throws {
        let client = ReleaseDetailsHTTPClient(
            responses: [
                .success(
                    HTTPResponse(
                        statusCode: 200,
                        data: makeDetailsJSON()
                    )
                )
            ]
        )
        let cache = InMemoryReleaseDetailsCache()
        let service = GitHubRuntimeReleaseDetailsClient(
            client: client,
            cache: cache
        )
        let tag = try LlamaBuildTag(parsing: "b10176")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let details = try await service.details(
            for: tag,
            now: now
        )

        #expect(details.buildTag == tag)
        #expect(
            details.publishedAt
                == Date(timeIntervalSince1970: 1_753_778_973)
        )
        #expect(details.changelog == "## What's Changed\n\n* Fix Metal")
        #expect(details.changelog?.contains("<details") == false)
        #expect(details.changelog?.contains("Website") == false)
        #expect(details.changelog?.contains("releases/download") == false)
        #expect(
            details.releasePageURL.absoluteString
                == "https://github.com/ggml-org/llama.cpp/releases/tag/b10176"
        )

        let request = try #require(
            await client.requests().first
        )
        #expect(
            request.url?.absoluteString
                == "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b10176"
        )
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/vnd.github+json"
        )
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == "LlamaDock"
        )
        #expect(
            request.value(
                forHTTPHeaderField: "X-GitHub-Api-Version"
            ) == "2022-11-28"
        )

        let cached = try #require(
            await cache.load(tag: tag)
        )
        #expect(cached.details == details)
        #expect(cached.fetchedAt == now)
    }

    @Test("uses cached details without another network request")
    func usesCache() async throws {
        let tag = try LlamaBuildTag(parsing: "b10176")
        let cached = CachedRuntimeReleaseDetails(
            details: makeDetails(tag: tag),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let client = ReleaseDetailsHTTPClient(responses: [])
        let service = GitHubRuntimeReleaseDetailsClient(
            client: client,
            cache: InMemoryReleaseDetailsCache(
                entries: [tag.tag: cached]
            )
        )

        let details = try await service.details(
            for: tag,
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(details == cached.details)
        #expect(await client.requests().isEmpty)
    }

    @Test("rejects a mismatched release tag")
    func rejectsMismatchedTag() async throws {
        let service = GitHubRuntimeReleaseDetailsClient(
            client: ReleaseDetailsHTTPClient(
                responses: [
                    .success(
                        HTTPResponse(
                            statusCode: 200,
                            data: makeDetailsJSON(
                                tag: "b10177"
                            )
                        )
                    )
                ]
            )
        )

        await #expect(
            throws: RuntimeReleaseError.invalidPayload(
                "The returned tag does not match b10176."
            )
        ) {
            try await service.details(
                for: LlamaBuildTag(
                    tag: "b10176",
                    build: 10_176
                ),
                now: Date()
            )
        }
    }

    @Test("persists one readable cache document per build tag")
    func persistsCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockReleaseDetailsTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let tag = try LlamaBuildTag(parsing: "b10176")
        let entry = CachedRuntimeReleaseDetails(
            details: makeDetails(tag: tag),
            fetchedAt: Date(timeIntervalSince1970: 200)
        )

        let first = JSONRuntimeReleaseDetailsCache(
            directory: directory
        )
        try await first.save(entry)

        let fileURL = directory.appending(
            path: "b10176.json",
            directoryHint: .notDirectory
        )
        let rawJSON = try String(
            contentsOf: fileURL,
            encoding: .utf8
        )
        #expect(rawJSON.contains(#""schemaVersion" : 2"#))
        #expect(rawJSON.contains(#""changelog" : "Fix Metal""#))

        let second = JSONRuntimeReleaseDetailsCache(
            directory: directory
        )
        #expect(try await second.load(tag: tag) == entry)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ) == ["b10176.json"]
        )
    }

    private func makeDetailsJSON(
        tag: String = "b10176"
    ) -> Data {
        Data(
            """
            {
              "tag_name": "\(tag)",
              "published_at": "2025-07-29T08:49:33Z",
              "body": "  <details open>\\n\\n## What's Changed\\n\\n* Fix Metal\\n\\n</details>\\n\\n**Website:**\\n- <https://llama.app>\\n\\n**macOS/iOS:**\\n- [macOS Apple Silicon](https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/llama-bin.tar.gz)  ",
              "html_url": "https://github.com/ggml-org/llama.cpp/releases/tag/\(tag)"
            }
            """.utf8
        )
    }

    private func makeDetails(
        tag: LlamaBuildTag
    ) -> RuntimeReleaseDetails {
        RuntimeReleaseDetails(
            buildTag: tag,
            publishedAt: Date(timeIntervalSince1970: 100),
            changelog: "Fix Metal",
            releasePageURL: URL(
                string: "https://github.com/ggml-org/llama.cpp/releases/tag/\(tag.tag)"
            )!
        )
    }
}

private actor ReleaseDetailsHTTPClient: HTTPRequesting {
    private var responses: [Result<HTTPResponse, Error>]
    private var recordedRequests: [URLRequest] = []

    init(
        responses: [Result<HTTPResponse, Error>]
    ) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) throws -> HTTPResponse {
        recordedRequests.append(request)
        return try responses.removeFirst().get()
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor InMemoryReleaseDetailsCache:
    RuntimeReleaseDetailsCaching
{
    private var entries:
        [String: CachedRuntimeReleaseDetails]

    init(
        entries: [String: CachedRuntimeReleaseDetails] = [:]
    ) {
        self.entries = entries
    }

    func load(
        tag: LlamaBuildTag
    ) -> CachedRuntimeReleaseDetails? {
        entries[tag.tag]
    }

    func save(
        _ entry: CachedRuntimeReleaseDetails
    ) {
        entries[entry.details.tag] = entry
    }
}
