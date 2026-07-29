import Foundation

public struct GitHubLatestRuntimeReleaseClient:
    RuntimeReleaseChecking,
    Sendable
{
    public static let officialEndpoint = URL(
        string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
    )!

    private let client: any HTTPRequesting
    private let cache: any RuntimeReleaseCaching
    private let selector: GitHubRuntimeAssetSelector
    private let endpoint: URL

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient(),
        cache: any RuntimeReleaseCaching = EmptyRuntimeReleaseCache(),
        selector: GitHubRuntimeAssetSelector = GitHubRuntimeAssetSelector(),
        endpoint: URL = Self.officialEndpoint
    ) {
        self.client = client
        self.cache = cache
        self.selector = selector
        self.endpoint = endpoint
    }

    public func checkLatest(
        now: Date = Date()
    ) async throws -> RuntimeReleaseCheck {
        let cached: CachedRuntimeRelease?
        let cacheLoadWarning: String?
        do {
            cached = try await cache.load()
            cacheLoadWarning = nil
        } catch {
            cached = nil
            cacheLoadWarning = "Release cache could not be read: \(diagnosticDescription(error))"
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "LlamaDock",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "2022-11-28",
            forHTTPHeaderField: "X-GitHub-Api-Version"
        )
        if let etag = cached?.etag {
            request.setValue(
                etag,
                forHTTPHeaderField: "If-None-Match"
            )
        }

        let response: HTTPResponse
        do {
            response = try await client.data(for: request)
        } catch {
            guard let cached else {
                throw RuntimeReleaseError.transport(
                    diagnosticDescription(error)
                )
            }
            let requestWarning = """
                Using cached release because the GitHub request failed: \
                \(diagnosticDescription(error))
                """
            return RuntimeReleaseCheck(
                release: cached.release,
                source: .staleCache,
                fetchedAt: cached.fetchedAt,
                warning: joinedWarnings(
                    cacheLoadWarning,
                    requestWarning
                )
            )
        }

        switch response.statusCode {
        case 200:
            return try await processFreshResponse(
                response,
                cached: cached,
                cacheLoadWarning: cacheLoadWarning,
                now: now
            )
        case 304:
            guard let cached else {
                throw RuntimeReleaseError.notModifiedWithoutCache
            }
            return RuntimeReleaseCheck(
                release: cached.release,
                source: .notModifiedCache,
                fetchedAt: cached.fetchedAt,
                warning: cacheLoadWarning
            )
        default:
            let error = RuntimeReleaseError.httpStatus(
                response.statusCode,
                message: githubMessage(from: response.data)
            )
            guard let cached else {
                throw error
            }
            return RuntimeReleaseCheck(
                release: cached.release,
                source: .staleCache,
                fetchedAt: cached.fetchedAt,
                warning: joinedWarnings(
                    cacheLoadWarning,
                    "Using cached release because \(error.localizedDescription)"
                )
            )
        }
    }

    private func processFreshResponse(
        _ response: HTTPResponse,
        cached: CachedRuntimeRelease?,
        cacheLoadWarning: String?,
        now: Date
    ) async throws -> RuntimeReleaseCheck {
        let release: ManagedRuntimeRelease
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(
                GitHubReleasePayload.self,
                from: response.data
            )
            let buildTag = try LlamaBuildTag(
                parsing: payload.tagName
            )
            let assets = payload.assets.map(\.runtimeAsset)
            release = ManagedRuntimeRelease(
                buildTag: buildTag,
                publishedAt: payload.publishedAt,
                asset: try selector.selectMacOSAppleSiliconAsset(
                    from: assets
                )
            )
        } catch let error as RuntimeReleaseError {
            return try staleOrThrow(
                error,
                cached: cached,
                cacheLoadWarning: cacheLoadWarning
            )
        } catch {
            return try staleOrThrow(
                RuntimeReleaseError.invalidPayload(
                    error.localizedDescription
                ),
                cached: cached,
                cacheLoadWarning: cacheLoadWarning
            )
        }

        let entry = CachedRuntimeRelease(
            release: release,
            etag: response.value(
                forHTTPHeaderField: "ETag"
            ),
            fetchedAt: now
        )
        var warning = cacheLoadWarning
        do {
            try await cache.save(entry)
        } catch {
            warning = joinedWarnings(
                warning,
                "Release cache could not be updated: \(diagnosticDescription(error))"
            )
        }

        return RuntimeReleaseCheck(
            release: release,
            source: .network,
            fetchedAt: now,
            warning: warning
        )
    }

    private func staleOrThrow(
        _ error: RuntimeReleaseError,
        cached: CachedRuntimeRelease?,
        cacheLoadWarning: String?
    ) throws -> RuntimeReleaseCheck {
        guard let cached else {
            throw error
        }
        return RuntimeReleaseCheck(
            release: cached.release,
            source: .staleCache,
            fetchedAt: cached.fetchedAt,
            warning: joinedWarnings(
                cacheLoadWarning,
                "Using cached release because \(error.localizedDescription)"
            )
        )
    }

    private func githubMessage(
        from data: Data
    ) -> String? {
        try? JSONDecoder()
            .decode(GitHubErrorPayload.self, from: data)
            .message
    }

    private func joinedWarnings(
        _ first: String?,
        _ second: String?
    ) -> String? {
        [first, second]
            .compactMap { warning in
                guard let warning, !warning.isEmpty else {
                    return nil
                }
                return warning
            }
            .joined(separator: " ")
            .nilIfEmpty
    }

    private func diagnosticDescription(
        _ error: any Error
    ) -> String {
        let localized = error.localizedDescription
        let typed = String(describing: error)
        guard localized != typed else {
            return localized
        }
        return "\(localized) [\(typed)]"
    }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let publishedAt: Date
    let assets: [GitHubReleaseAssetPayload]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubReleaseAssetPayload: Decodable {
    let id: Int64
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let contentType: String?
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
        case digest
    }

    var runtimeAsset: GitHubRuntimeReleaseAsset {
        GitHubRuntimeReleaseAsset(
            id: id,
            name: name,
            downloadURL: browserDownloadURL,
            size: size,
            contentType: contentType,
            digest: digest
        )
    }
}

private struct GitHubErrorPayload: Decodable {
    let message: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
