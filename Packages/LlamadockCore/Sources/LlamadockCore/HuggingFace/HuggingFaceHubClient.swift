import Foundation

public enum HuggingFaceHubError:
    Error,
    Equatable,
    Sendable
{
    case invalidQuery
    case invalidRepositoryID(String)
    case invalidRevision(String)
    case unsafeFilePath(String)
    case authenticationRequired
    case accessDenied
    case repositoryNotFound(String)
    case rateLimited
    case httpStatus(Int, message: String?)
    case invalidPayload(String)
    case transport(String)
}

extension HuggingFaceHubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            "Enter a model name or Hugging Face repository."
        case .invalidRepositoryID(let id):
            "Invalid Hugging Face repository ID: \(id)."
        case .invalidRevision(let revision):
            "Invalid Hugging Face revision: \(revision)."
        case .unsafeFilePath(let path):
            "The repository returned an unsafe file path: \(path)."
        case .authenticationRequired:
            "A Hugging Face token is required for this repository."
        case .accessDenied:
            "The Hugging Face token does not grant access to this repository."
        case .repositoryNotFound(let id):
            "Hugging Face repository not found: \(id)."
        case .rateLimited:
            "Hugging Face rate limited the request. Try again later."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                "Hugging Face returned HTTP \(status): \(message)"
            } else {
                "Hugging Face returned HTTP \(status)."
            }
        case .invalidPayload(let reason):
            "Hugging Face returned an invalid response: \(reason)"
        case .transport(let reason):
            "Could not reach Hugging Face: \(reason)"
        }
    }
}

public protocol HuggingFaceHubServing: Sendable {
    func searchModels(
        query: String,
        limit: Int,
        token: String?
    ) async throws -> [HuggingFaceRepository]

    func repositoryFiles(
        reference: HuggingFaceRepositoryReference,
        token: String?
    ) async throws -> [HuggingFaceRepositoryFile]
}

public struct HuggingFaceHubClient:
    HuggingFaceHubServing,
    Sendable
{
    public static let endpoint = URL(
        string: "https://huggingface.co"
    )!

    private let client: any HTTPRequesting
    private let endpoint: URL

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient(),
        endpoint: URL = Self.endpoint
    ) {
        self.client = client
        self.endpoint = endpoint
    }

    public func searchModels(
        query: String,
        limit: Int = 50,
        token: String? = nil
    ) async throws -> [HuggingFaceRepository] {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else {
            throw HuggingFaceHubError.invalidQuery
        }
        let boundedLimit = min(max(limit, 1), 100)
        guard var components = URLComponents(
            url: endpoint.appending(path: "api/models"),
            resolvingAgainstBaseURL: false
        ) else {
            throw HuggingFaceHubError.invalidQuery
        }
        components.queryItems = [
            URLQueryItem(name: "search", value: normalizedQuery),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(boundedLimit)),
        ]
        guard let url = components.url else {
            throw HuggingFaceHubError.invalidQuery
        }

        let response = try await request(url: url, token: token)
        try validate(response, repositoryID: nil)
        do {
            let payloads = try JSONDecoder().decode(
                [RepositoryPayload].self,
                from: response.data
            )
            var repositories: [HuggingFaceRepository] = []
            for payload in payloads {
                guard let repository = payload.repository else {
                    throw HuggingFaceHubError.invalidPayload(
                        "A search result is missing its repository ID."
                    )
                }
                repositories.append(repository)
            }
            return repositories
        } catch {
            throw HuggingFaceHubError.invalidPayload(
                error.localizedDescription
            )
        }
    }

    public func repositoryFiles(
        reference: HuggingFaceRepositoryReference,
        token: String? = nil
    ) async throws -> [HuggingFaceRepositoryFile] {
        let segments = reference.repositoryID.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            segments.count == 2,
            segments.allSatisfy({
                isSafePathSegment(String($0))
            })
        else {
            throw HuggingFaceHubError.invalidRepositoryID(
                reference.repositoryID
            )
        }
        guard isSafeRevision(reference.revision) else {
            throw HuggingFaceHubError.invalidRevision(
                reference.revision
            )
        }

        let encodedSegments = [
            "api",
            "models",
            String(segments[0]),
            String(segments[1]),
            "tree",
            reference.revision,
        ].map(percentEncodedPathSegment)
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw HuggingFaceHubError.invalidRepositoryID(
                reference.repositoryID
            )
        }
        components.percentEncodedPath = "/"
            + encodedSegments.joined(separator: "/")
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "expand", value: "false"),
        ]
        guard let url = components.url else {
            throw HuggingFaceHubError.invalidRepositoryID(
                reference.repositoryID
            )
        }

        var nextURL: URL? = url
        var pagesRead = 0
        var files: [HuggingFaceRepositoryFile] = []
        while let pageURL = nextURL {
            pagesRead += 1
            guard pagesRead <= 100 else {
                throw HuggingFaceHubError.invalidPayload(
                    "The repository tree exceeded 100 pages."
                )
            }

            let response = try await request(
                url: pageURL,
                token: token
            )
            try validate(
                response,
                repositoryID: reference.repositoryID
            )
            do {
                let payloads = try JSONDecoder().decode(
                    [TreeEntryPayload].self,
                    from: response.data
                )
                files.append(
                    contentsOf: payloads.compactMap(
                        \.repositoryFile
                    )
                )
            } catch let error as HuggingFaceHubError {
                throw error
            } catch {
                throw HuggingFaceHubError.invalidPayload(
                    error.localizedDescription
                )
            }
            nextURL = try nextPageURL(
                from: response,
                relativeTo: pageURL
            )
        }
        return files
    }

    public func resolveURL(
        reference: HuggingFaceRepositoryReference,
        filePath: String
    ) throws -> URL {
        let repositorySegments = reference.repositoryID.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            repositorySegments.count == 2,
            repositorySegments.allSatisfy({
                isSafePathSegment(String($0))
            })
        else {
            throw HuggingFaceHubError.invalidRepositoryID(
                reference.repositoryID
            )
        }
        guard isSafeRevision(reference.revision) else {
            throw HuggingFaceHubError.invalidRevision(
                reference.revision
            )
        }
        let fileSegments = filePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            !filePath.hasPrefix("/"),
            !fileSegments.isEmpty,
            fileSegments.allSatisfy({
                isSafePathSegment(String($0))
            })
        else {
            throw HuggingFaceHubError.unsafeFilePath(filePath)
        }

        let segments = repositorySegments.map(String.init)
            + ["resolve", reference.revision]
            + fileSegments.map(String.init)
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw HuggingFaceHubError.unsafeFilePath(filePath)
        }
        components.percentEncodedPath = "/"
            + segments.map(percentEncodedPathSegment)
                .joined(separator: "/")
        components.queryItems = [
            URLQueryItem(name: "download", value: "true"),
        ]
        guard let url = components.url else {
            throw HuggingFaceHubError.unsafeFilePath(filePath)
        }
        return url
    }

    private func request(
        url: URL,
        token: String?
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "LlamaDock",
            forHTTPHeaderField: "User-Agent"
        )
        if let token, !token.isEmpty {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        do {
            return try await client.data(for: request)
        } catch {
            throw HuggingFaceHubError.transport(
                error.localizedDescription
            )
        }
    }

    private func nextPageURL(
        from response: HTTPResponse,
        relativeTo currentURL: URL
    ) throws -> URL? {
        guard
            let linkHeader = response.value(
                forHTTPHeaderField: "Link"
            )
        else {
            return nil
        }
        for entry in linkHeader.split(separator: ",") {
            let components = entry.split(separator: ";")
            guard
                let target = components.first?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                target.hasPrefix("<"),
                target.hasSuffix(">"),
                components.dropFirst().contains(where: {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == #"rel="next""#
                })
            else {
                continue
            }
            let value = String(
                target.dropFirst().dropLast()
            )
            guard
                let url = URL(
                    string: value,
                    relativeTo: currentURL
                )?.absoluteURL,
                url.scheme?.lowercased()
                    == endpoint.scheme?.lowercased(),
                url.host?.lowercased()
                    == endpoint.host?.lowercased()
            else {
                throw HuggingFaceHubError.invalidPayload(
                    "The repository pagination link leaves huggingface.co."
                )
            }
            return url
        }
        return nil
    }

    private func validate(
        _ response: HTTPResponse,
        repositoryID: String?
    ) throws {
        guard response.statusCode != 401 else {
            throw HuggingFaceHubError.authenticationRequired
        }
        guard response.statusCode != 403 else {
            throw HuggingFaceHubError.accessDenied
        }
        guard response.statusCode != 404 else {
            throw HuggingFaceHubError.repositoryNotFound(
                repositoryID ?? "requested model"
            )
        }
        guard response.statusCode != 429 else {
            throw HuggingFaceHubError.rateLimited
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HuggingFaceHubError.httpStatus(
                response.statusCode,
                message: errorMessage(from: response.data)
            )
        }
    }

    private func errorMessage(
        from data: Data
    ) -> String? {
        try? JSONDecoder()
            .decode(ErrorPayload.self, from: data)
            .error
    }

    private func isSafeRevision(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("\\")
            && !value.contains(where: \.isNewline)
    }

    private func isSafePathSegment(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("\\")
            && !value.contains(where: \.isNewline)
    }

    private func percentEncodedPathSegment(
        _ value: String
    ) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            )
        ) ?? ""
    }
}

private struct RepositoryPayload: Decodable {
    let id: String?
    let modelID: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let gated: GatedPayload?
    let isPrivate: Bool?
    let pipelineTag: String?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case modelID = "modelId"
        case downloads
        case likes
        case lastModified
        case gated
        case isPrivate = "private"
        case pipelineTag = "pipeline_tag"
        case tags
    }

    var repository: HuggingFaceRepository? {
        guard let repositoryID = modelID ?? id else {
            return nil
        }
        return HuggingFaceRepository(
            id: repositoryID,
            downloads: max(downloads ?? 0, 0),
            likes: max(likes ?? 0, 0),
            lastModified: lastModified.flatMap(parseISO8601),
            gated: gated?.status ?? .none,
            isPrivate: isPrivate ?? false,
            pipelineTag: pipelineTag,
            tags: tags ?? []
        )
    }

    private func parseISO8601(
        _ value: String
    ) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }
}

private enum GatedPayload: Decodable {
    case boolean(Bool)
    case mode(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .mode(try container.decode(String.self))
        }
    }

    var status: HuggingFaceGatedStatus {
        switch self {
        case .boolean(false):
            .none
        case .boolean(true):
            .gated
        case .mode(let value):
            switch value.lowercased() {
            case "auto", "automatic":
                .automatic
            case "manual":
                .manual
            default:
                .gated
            }
        }
    }
}

private struct TreeEntryPayload: Decodable {
    let type: String
    let path: String
    let size: Int64?
    let oid: String?
    let lfs: LFSPayload?

    var repositoryFile: HuggingFaceRepositoryFile? {
        guard type == "file" else {
            return nil
        }
        return HuggingFaceRepositoryFile(
            path: path,
            size: max(lfs?.size ?? size ?? 0, 0),
            gitOID: oid,
            lfsOID: lfs?.oid
        )
    }
}

private struct LFSPayload: Decodable {
    let oid: String?
    let size: Int64?
}

private struct ErrorPayload: Decodable {
    let error: String?
}
