import Foundation

public struct RuntimeReleaseDetails:
    Codable,
    Equatable,
    Sendable
{
    public let buildTag: LlamaBuildTag
    public let publishedAt: Date
    public let changelog: String?
    public let releasePageURL: URL

    public init(
        buildTag: LlamaBuildTag,
        publishedAt: Date,
        changelog: String?,
        releasePageURL: URL
    ) {
        self.buildTag = buildTag
        self.publishedAt = publishedAt
        self.changelog = changelog
        self.releasePageURL = releasePageURL
    }

    public var tag: String {
        buildTag.tag
    }
}

public struct CachedRuntimeReleaseDetails:
    Codable,
    Equatable,
    Sendable
{
    public let details: RuntimeReleaseDetails
    public let fetchedAt: Date

    public init(
        details: RuntimeReleaseDetails,
        fetchedAt: Date
    ) {
        self.details = details
        self.fetchedAt = fetchedAt
    }
}

public protocol RuntimeReleaseDetailsCaching: Sendable {
    func load(
        tag: LlamaBuildTag
    ) async throws -> CachedRuntimeReleaseDetails?
    func save(
        _ entry: CachedRuntimeReleaseDetails
    ) async throws
}

public actor EmptyRuntimeReleaseDetailsCache:
    RuntimeReleaseDetailsCaching
{
    public init() {}

    public func load(
        tag: LlamaBuildTag
    ) -> CachedRuntimeReleaseDetails? {
        nil
    }

    public func save(
        _ entry: CachedRuntimeReleaseDetails
    ) {}
}

public enum RuntimeReleaseDetailsCacheError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedSchemaVersion(Int)
    case invalidEntry(String)
}

extension RuntimeReleaseDetailsCacheError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported runtime release details cache schema: \(version)"
        case .invalidEntry(let reason):
            "The cached runtime release details are invalid: \(reason)"
        }
    }
}

public actor JSONRuntimeReleaseDetailsCache:
    RuntimeReleaseDetailsCaching
{
    private static let currentSchemaVersion = 2

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directory: URL,
        fileManager: FileManager = .default
    ) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load(
        tag: LlamaBuildTag
    ) throws -> CachedRuntimeReleaseDetails? {
        let fileURL = fileURL(for: tag)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let document = try decoder.decode(
            CacheDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard
            document.schemaVersion == Self.currentSchemaVersion
        else {
            throw RuntimeReleaseDetailsCacheError
                .unsupportedSchemaVersion(
                    document.schemaVersion
                )
        }
        try validate(document.entry, expectedTag: tag)
        return document.entry
    }

    public func save(
        _ entry: CachedRuntimeReleaseDetails
    ) throws {
        try validate(
            entry,
            expectedTag: entry.details.buildTag
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(
            CacheDocument(
                schemaVersion: Self.currentSchemaVersion,
                entry: entry
            )
        )
        try atomicallyWrite(
            data,
            to: fileURL(for: entry.details.buildTag)
        )
    }

    private func validate(
        _ entry: CachedRuntimeReleaseDetails,
        expectedTag: LlamaBuildTag
    ) throws {
        guard entry.details.buildTag == expectedTag else {
            throw RuntimeReleaseDetailsCacheError.invalidEntry(
                "The release tag does not match the cache file."
            )
        }
        guard
            entry.details.releasePageURL.scheme?.lowercased()
                == "https",
            entry.details.releasePageURL.host?.lowercased()
                == "github.com"
        else {
            throw RuntimeReleaseDetailsCacheError.invalidEntry(
                "The release page URL is not an official HTTPS URL."
            )
        }
    }

    private func fileURL(
        for tag: LlamaBuildTag
    ) -> URL {
        directory.appending(
            path: "\(tag.tag).json",
            directoryHint: .notDirectory
        )
    }

    private func atomicallyWrite(
        _ data: Data,
        to destination: URL
    ) throws {
        let temporaryURL = directory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try data.write(
                to: temporaryURL,
                options: .withoutOverwriting
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: destination
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private struct CacheDocument: Codable {
        let schemaVersion: Int
        let entry: CachedRuntimeReleaseDetails
    }
}

public protocol RuntimeReleaseDetailsFetching: Sendable {
    func details(
        for tag: LlamaBuildTag,
        now: Date
    ) async throws -> RuntimeReleaseDetails
}

public struct GitHubRuntimeReleaseDetailsClient:
    RuntimeReleaseDetailsFetching,
    Sendable
{
    public static let officialEndpointRoot = URL(
        string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/"
    )!

    private static let maximumChangelogCharacters = 200_000

    private let client: any HTTPRequesting
    private let cache: any RuntimeReleaseDetailsCaching
    private let endpointRoot: URL

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient(),
        cache: any RuntimeReleaseDetailsCaching =
            EmptyRuntimeReleaseDetailsCache(),
        endpointRoot: URL = Self.officialEndpointRoot
    ) {
        self.client = client
        self.cache = cache
        self.endpointRoot = endpointRoot
    }

    public func details(
        for tag: LlamaBuildTag,
        now: Date = Date()
    ) async throws -> RuntimeReleaseDetails {
        if let cached = try? await cache.load(tag: tag) {
            return cached.details
        }

        var request = URLRequest(
            url: endpointRoot.appending(
                path: tag.tag,
                directoryHint: .notDirectory
            )
        )
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

        let response: HTTPResponse
        do {
            response = try await client.data(for: request)
        } catch {
            throw RuntimeReleaseError.transport(
                diagnosticDescription(error)
            )
        }
        guard response.statusCode == 200 else {
            throw RuntimeReleaseError.httpStatus(
                response.statusCode,
                message: githubMessage(from: response.data)
            )
        }

        let details: RuntimeReleaseDetails
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(
                GitHubReleaseDetailsPayload.self,
                from: response.data
            )
            let returnedTag = try LlamaBuildTag(
                parsing: payload.tagName
            )
            guard returnedTag == tag else {
                throw RuntimeReleaseError.invalidPayload(
                    "The returned tag does not match \(tag.tag)."
                )
            }
            guard
                payload.htmlURL.scheme?.lowercased() == "https",
                payload.htmlURL.host?.lowercased() == "github.com"
            else {
                throw RuntimeReleaseError.invalidPayload(
                    "The release page URL is not an official HTTPS URL."
                )
            }

            let changelog = sanitizedChangelog(
                from: payload.body
            )
            guard
                changelog?.count
                    ?? 0 <= Self.maximumChangelogCharacters
            else {
                throw RuntimeReleaseError.invalidPayload(
                    "The changelog is too large."
                )
            }
            details = RuntimeReleaseDetails(
                buildTag: returnedTag,
                publishedAt: payload.publishedAt,
                changelog: changelog,
                releasePageURL: payload.htmlURL
            )
        } catch let error as RuntimeReleaseError {
            throw error
        } catch {
            throw RuntimeReleaseError.invalidPayload(
                error.localizedDescription
            )
        }

        try? await cache.save(
            CachedRuntimeReleaseDetails(
                details: details,
                fetchedAt: now
            )
        )
        return details
    }

    private func githubMessage(
        from data: Data
    ) -> String? {
        try? JSONDecoder()
            .decode(
                GitHubReleaseDetailsErrorPayload.self,
                from: data
            )
            .message
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

private func sanitizedChangelog(
    from releaseBody: String?
) -> String? {
    guard
        var changelog = releaseBody?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !changelog.isEmpty
    else {
        return nil
    }

    if
        let detailsStart = changelog.range(
            of: "<details",
            options: .caseInsensitive
        ),
        let openingTagEnd = changelog.range(
            of: ">",
            range:
                detailsStart.upperBound..<changelog.endIndex
        ),
        let detailsEnd = changelog.range(
            of: "</details>",
            options: .caseInsensitive,
            range:
                openingTagEnd.upperBound..<changelog.endIndex
        )
    {
        changelog = String(
            changelog[
                openingTagEnd.upperBound..<detailsEnd.lowerBound
            ]
        )
    }

    var cleanedLines: [String] = []
    for line in changelog.components(separatedBy: .newlines) {
        if isReleaseArtifactSection(line) {
            break
        }

        let withoutHTML = line.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        let withoutTrailingWhitespace =
            withoutHTML.replacingOccurrences(
                of: #"[ \t]+$"#,
                with: "",
                options: .regularExpression
            )

        if withoutTrailingWhitespace
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
        {
            if cleanedLines.last?.isEmpty == false {
                cleanedLines.append("")
            }
        } else {
            cleanedLines.append(withoutTrailingWhitespace)
        }
    }

    while cleanedLines.first?.isEmpty == true {
        cleanedLines.removeFirst()
    }
    while cleanedLines.last?.isEmpty == true {
        cleanedLines.removeLast()
    }

    return cleanedLines.joined(separator: "\n").nilIfEmpty
}

private func isReleaseArtifactSection(
    _ line: String
) -> Bool {
    let heading = line
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(
            in: CharacterSet(charactersIn: "#*_")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    return [
        "website:",
        "macos/ios:",
        "linux:",
        "android:",
        "windows:",
        "openeuler:",
        "ui:",
    ].contains(heading)
}

private struct GitHubReleaseDetailsPayload: Decodable {
    let tagName: String
    let publishedAt: Date
    let body: String?
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case body
        case htmlURL = "html_url"
    }
}

private struct GitHubReleaseDetailsErrorPayload: Decodable {
    let message: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
