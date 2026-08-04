import Foundation

public enum ModelScopeHubError:
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

extension ModelScopeHubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            "Enter a model name or ModelScope repository."
        case .invalidRepositoryID(let id):
            "Invalid ModelScope repository ID: \(id)."
        case .invalidRevision(let revision):
            "Invalid ModelScope revision: \(revision)."
        case .unsafeFilePath(let path):
            "The repository returned an unsafe file path: \(path)."
        case .authenticationRequired:
            "This ModelScope repository requires authentication. LlamaDock currently supports public ModelScope repositories."
        case .accessDenied:
            "ModelScope denied access to this repository."
        case .repositoryNotFound(let id):
            "ModelScope repository not found: \(id)."
        case .rateLimited:
            "ModelScope rate limited the request. Try again later."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                "ModelScope returned status \(status): \(message)"
            } else {
                "ModelScope returned status \(status)."
            }
        case .invalidPayload(let reason):
            "ModelScope returned an invalid response: \(reason)"
        case .transport(let reason):
            "Could not reach ModelScope: \(reason)"
        }
    }
}

public protocol ModelScopeHubServing: Sendable {
    func searchModels(
        query: String,
        limit: Int
    ) async throws -> [HuggingFaceRepository]

    func repositoryFiles(
        reference: HuggingFaceRepositoryReference
    ) async throws -> [HuggingFaceRepositoryFile]
}

public protocol ModelScopeFileURLResolving: Sendable {
    func resolveURL(
        reference: HuggingFaceRepositoryReference,
        filePath: String
    ) throws -> URL
}

public struct ModelScopeHubClient:
    ModelScopeHubServing,
    ModelScopeFileURLResolving,
    Sendable
{
    public static let endpoint = URL(
        string: "https://modelscope.cn"
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
        limit: Int = 50
    ) async throws -> [HuggingFaceRepository] {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else {
            throw ModelScopeHubError.invalidQuery
        }
        let boundedLimit = min(max(limit, 1), 50)
        guard var components = URLComponents(
            url: endpoint.appending(path: "openapi/v1/models"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ModelScopeHubError.invalidQuery
        }
        components.queryItems = [
            URLQueryItem(name: "search", value: normalizedQuery),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "page_size", value: String(boundedLimit)),
            URLQueryItem(name: "filter.library", value: "gguf"),
        ]
        guard let url = components.url else {
            throw ModelScopeHubError.invalidQuery
        }

        let response = try await request(url: url)
        try validate(response, repositoryID: nil)
        do {
            let envelope = try JSONDecoder().decode(
                SearchEnvelope.self,
                from: response.data
            )
            guard envelope.success != false else {
                throw ModelScopeHubError.invalidPayload(
                    envelope.message ?? "The search request failed."
                )
            }
            return try envelope.data.models.map { payload in
                guard let repository = payload.repository else {
                    throw ModelScopeHubError.invalidPayload(
                        "A search result is missing its repository ID."
                    )
                }
                return repository
            }
        } catch let error as ModelScopeHubError {
            throw error
        } catch {
            throw ModelScopeHubError.invalidPayload(
                error.localizedDescription
            )
        }
    }

    public func repositoryFiles(
        reference: HuggingFaceRepositoryReference
    ) async throws -> [HuggingFaceRepositoryFile] {
        let repositorySegments = try validatedRepositorySegments(
            reference.repositoryID
        )
        try validateRevision(reference.revision)

        let segments = ["api", "v1", "models"]
            + repositorySegments
            + ["repo", "files"]
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ModelScopeHubError.invalidRepositoryID(
                reference.repositoryID
            )
        }
        components.percentEncodedPath = "/"
            + segments.map(percentEncodedPathSegment)
                .joined(separator: "/")
        components.queryItems = [
            URLQueryItem(
                name: "Revision",
                value: reference.revision
            ),
            URLQueryItem(name: "Recursive", value: "true"),
        ]
        guard let url = components.url else {
            throw ModelScopeHubError.invalidRepositoryID(
                reference.repositoryID
            )
        }

        let response = try await request(url: url)
        try validate(
            response,
            repositoryID: reference.repositoryID
        )
        do {
            let envelope = try JSONDecoder().decode(
                FileTreeEnvelope.self,
                from: response.data
            )
            guard envelope.code == 200 else {
                throw ModelScopeHubError.httpStatus(
                    envelope.code,
                    message: envelope.message
                )
            }
            return envelope.data.files.compactMap(
                \.repositoryFile
            )
        } catch let error as ModelScopeHubError {
            throw error
        } catch {
            throw ModelScopeHubError.invalidPayload(
                error.localizedDescription
            )
        }
    }

    public func resolveURL(
        reference: HuggingFaceRepositoryReference,
        filePath: String
    ) throws -> URL {
        let repositorySegments = try validatedRepositorySegments(
            reference.repositoryID
        )
        try validateRevision(reference.revision)
        try validateFilePath(filePath)

        let segments = ["api", "v1", "models"]
            + repositorySegments
            + ["repo"]
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ModelScopeHubError.unsafeFilePath(filePath)
        }
        components.percentEncodedPath = "/"
            + segments.map(percentEncodedPathSegment)
                .joined(separator: "/")
        components.queryItems = [
            URLQueryItem(
                name: "Revision",
                value: reference.revision
            ),
            URLQueryItem(name: "FilePath", value: filePath),
        ]
        guard let url = components.url else {
            throw ModelScopeHubError.unsafeFilePath(filePath)
        }
        return url
    }

    private func request(
        url: URL
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
        do {
            return try await client.data(for: request)
        } catch {
            throw ModelScopeHubError.transport(
                error.localizedDescription
            )
        }
    }

    private func validate(
        _ response: HTTPResponse,
        repositoryID: String?
    ) throws {
        guard response.statusCode != 401 else {
            throw ModelScopeHubError.authenticationRequired
        }
        guard response.statusCode != 403 else {
            throw ModelScopeHubError.accessDenied
        }
        guard response.statusCode != 404 else {
            throw ModelScopeHubError.repositoryNotFound(
                repositoryID ?? "requested model"
            )
        }
        guard response.statusCode != 429 else {
            throw ModelScopeHubError.rateLimited
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ModelScopeHubError.httpStatus(
                response.statusCode,
                message: errorMessage(from: response.data)
            )
        }
    }

    private func errorMessage(
        from data: Data
    ) -> String? {
        (try? JSONDecoder().decode(
            ErrorEnvelope.self,
            from: data
        ))?.message
    }

    private func validatedRepositorySegments(
        _ repositoryID: String
    ) throws -> [String] {
        let segments = repositoryID.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            segments.count == 2,
            segments.allSatisfy(isSafePathSegment)
        else {
            throw ModelScopeHubError.invalidRepositoryID(
                repositoryID
            )
        }
        return segments
    }

    private func validateRevision(
        _ revision: String
    ) throws {
        guard
            !revision.isEmpty,
            revision != ".",
            revision != "..",
            !revision.contains("\\"),
            !revision.contains(where: \.isNewline)
        else {
            throw ModelScopeHubError.invalidRevision(revision)
        }
    }

    private func validateFilePath(
        _ filePath: String
    ) throws {
        let segments = filePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            !filePath.hasPrefix("/"),
            !segments.isEmpty,
            segments.allSatisfy(isSafePathSegment)
        else {
            throw ModelScopeHubError.unsafeFilePath(filePath)
        }
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

private struct SearchEnvelope: Decodable {
    let success: Bool?
    let message: String?
    let data: SearchData

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case data
    }
}

private struct SearchData: Decodable {
    let models: [ModelPayload]
}

private struct ModelPayload: Decodable {
    let id: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let isPrivate: Bool?
    let gated: Bool?
    let tasks: [String]?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case lastModified = "last_modified"
        case isPrivate = "private"
        case gated
        case tasks
        case tags
    }

    var repository: HuggingFaceRepository? {
        guard let id else {
            return nil
        }
        return HuggingFaceRepository(
            id: id,
            downloads: max(downloads ?? 0, 0),
            likes: max(likes ?? 0, 0),
            lastModified: lastModified.flatMap(parseISO8601),
            gated: gated == true ? .gated : .none,
            isPrivate: isPrivate ?? false,
            pipelineTag: tasks?.first,
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

private struct FileTreeEnvelope: Decodable {
    let code: Int
    let data: FileTreeData
    let message: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case data = "Data"
        case message = "Message"
    }
}

private struct FileTreeData: Decodable {
    let files: [FilePayload]

    enum CodingKeys: String, CodingKey {
        case files = "Files"
    }
}

private struct FilePayload: Decodable {
    let type: String
    let path: String
    let size: Int64?
    let revision: String?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case path = "Path"
        case size = "Size"
        case revision = "Revision"
        case sha256 = "Sha256"
    }

    var repositoryFile: HuggingFaceRepositoryFile? {
        guard type.caseInsensitiveCompare("blob") == .orderedSame else {
            return nil
        }
        return HuggingFaceRepositoryFile(
            path: path,
            size: max(size ?? 0, 0),
            gitOID: revision,
            lfsOID: sha256
        )
    }
}

private struct ErrorEnvelope: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
        case message
        case capitalizedMessage = "Message"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        message = try container.decodeIfPresent(
            String.self,
            forKey: .message
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .capitalizedMessage
        )
    }
}
