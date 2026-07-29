import Foundation
import Testing
@testable import LlamadockCore

@Suite("LlamaDock app release checker")
struct AppReleaseCheckerTests {
    @Test("detects a newer semantic release with required headers")
    func detectsNewerRelease() async throws {
        let client = AppReleaseFixtureHTTPClient(
            response: HTTPResponse(
                statusCode: 200,
                data: releasePayload(
                    tag: "v1.2.0",
                    url:
                        "https://github.com/boyzwj/Llamadock/releases/tag/v1.2.0"
                )
            )
        )
        let now = Date(timeIntervalSince1970: 123)

        let check = try await GitHubAppReleaseChecker(
            client: client
        ).checkLatest(
            currentVersion: "1.1",
            now: now
        )

        #expect(check.currentVersion == "1.1.0")
        #expect(check.release.version == "1.2.0")
        #expect(check.isUpdateAvailable)
        #expect(check.checkedAt == now)
        let request = try #require(
            await client.requests().first
        )
        #expect(
            request.value(
                forHTTPHeaderField: "Accept"
            ) == "application/vnd.github+json"
        )
        #expect(
            request.value(
                forHTTPHeaderField: "X-GitHub-Api-Version"
            ) == "2022-11-28"
        )
    }

    @Test("reports up to date and rejects unsafe release pages")
    func validatesReleasePage() async throws {
        let upToDate = try await GitHubAppReleaseChecker(
            client: AppReleaseFixtureHTTPClient(
                response: HTTPResponse(
                    statusCode: 200,
                    data: releasePayload(
                        tag: "1.0.0",
                        url:
                            "https://github.com/boyzwj/Llamadock/releases/tag/v1.0.0"
                    )
                )
            )
        ).checkLatest(currentVersion: "1.0.0")
        #expect(!upToDate.isUpdateAvailable)

        await #expect(
            throws: AppReleaseError.self
        ) {
            _ = try await GitHubAppReleaseChecker(
                client: AppReleaseFixtureHTTPClient(
                    response: HTTPResponse(
                        statusCode: 200,
                        data: releasePayload(
                            tag: "1.1.0",
                            url:
                                "http://example.com/fake"
                        )
                    )
                )
            ).checkLatest(currentVersion: "1.0.0")
        }
    }

    @Test("maps GitHub failures and invalid versions")
    func mapsFailures() async {
        await #expect(
            throws: AppReleaseError.invalidVersion("beta")
        ) {
            _ = try await GitHubAppReleaseChecker(
                client: AppReleaseFixtureHTTPClient(
                    response: HTTPResponse(
                        statusCode: 200,
                        data: Data()
                    )
                )
            ).checkLatest(currentVersion: "beta")
        }

        await #expect(
            throws: AppReleaseError.httpStatus(
                403,
                message: "rate limited"
            )
        ) {
            _ = try await GitHubAppReleaseChecker(
                client: AppReleaseFixtureHTTPClient(
                    response: HTTPResponse(
                        statusCode: 403,
                        data: Data(
                            #"{"message":"rate limited"}"#.utf8
                        )
                    )
                )
            ).checkLatest(currentVersion: "1.0.0")
        }
    }

    private func releasePayload(
        tag: String,
        url: String
    ) -> Data {
        Data(
            """
            {
              "tag_name": "\(tag)",
              "name": "LlamaDock \(tag)",
              "published_at": "2026-07-29T12:00:00Z",
              "html_url": "\(url)"
            }
            """.utf8
        )
    }
}

private actor AppReleaseFixtureHTTPClient: HTTPRequesting {
    private let response: HTTPResponse
    private var recordedRequests: [URLRequest] = []

    init(
        response: HTTPResponse
    ) {
        self.response = response
    }

    func data(
        for request: URLRequest
    ) async throws -> HTTPResponse {
        recordedRequests.append(request)
        return response
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
