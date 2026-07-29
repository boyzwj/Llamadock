import Foundation

public struct AppRelease:
    Equatable,
    Sendable
{
    public let tag: String
    public let version: String
    public let name: String
    public let publishedAt: Date
    public let releasePageURL: URL

    public init(
        tag: String,
        version: String,
        name: String,
        publishedAt: Date,
        releasePageURL: URL
    ) {
        self.tag = tag
        self.version = version
        self.name = name
        self.publishedAt = publishedAt
        self.releasePageURL = releasePageURL
    }
}

public struct AppUpdateCheck:
    Equatable,
    Sendable
{
    public let currentVersion: String
    public let release: AppRelease
    public let isUpdateAvailable: Bool
    public let checkedAt: Date

    public init(
        currentVersion: String,
        release: AppRelease,
        isUpdateAvailable: Bool,
        checkedAt: Date
    ) {
        self.currentVersion = currentVersion
        self.release = release
        self.isUpdateAvailable = isUpdateAvailable
        self.checkedAt = checkedAt
    }
}

public enum AppReleaseError:
    Error,
    Equatable,
    Sendable
{
    case invalidVersion(String)
    case httpStatus(Int, message: String?)
    case invalidPayload(String)
    case unsafeReleaseURL(URL)
    case transport(String)
}

extension AppReleaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let value):
            "Invalid LlamaDock release version: \(value)"
        case .httpStatus(let status, let message):
            "GitHub returned HTTP \(status)"
                + (message.map { ": \($0)" } ?? ".")
        case .invalidPayload(let reason):
            "GitHub returned an invalid LlamaDock release: \(reason)"
        case .unsafeReleaseURL(let url):
            "GitHub returned an unsafe release page URL: \(url.absoluteString)"
        case .transport(let reason):
            "Could not check for a LlamaDock update: \(reason)"
        }
    }
}

public protocol AppReleaseChecking: Sendable {
    func checkLatest(
        currentVersion: String,
        now: Date
    ) async throws -> AppUpdateCheck
}

public extension AppReleaseChecking {
    func checkLatest(
        currentVersion: String
    ) async throws -> AppUpdateCheck {
        try await checkLatest(
            currentVersion: currentVersion,
            now: Date()
        )
    }
}

public struct GitHubAppReleaseChecker:
    AppReleaseChecking,
    Sendable
{
    public static let officialEndpoint = URL(
        string:
            "https://api.github.com/repos/boyzwj/Llamadock/releases/latest"
    )!

    private let client: any HTTPRequesting
    private let endpoint: URL

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient(),
        endpoint: URL = Self.officialEndpoint
    ) {
        self.client = client
        self.endpoint = endpoint
    }

    public func checkLatest(
        currentVersion: String,
        now: Date = Date()
    ) async throws -> AppUpdateCheck {
        let installedVersion = try SemanticAppVersion(
            parsing: currentVersion
        )
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

        let response: HTTPResponse
        do {
            response = try await client.data(for: request)
        } catch {
            throw AppReleaseError.transport(
                diagnosticDescription(error)
            )
        }
        guard response.statusCode == 200 else {
            throw AppReleaseError.httpStatus(
                response.statusCode,
                message: githubMessage(from: response.data)
            )
        }

        let payload: GitHubAppReleasePayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(
                GitHubAppReleasePayload.self,
                from: response.data
            )
        } catch {
            throw AppReleaseError.invalidPayload(
                error.localizedDescription
            )
        }
        let latestVersion = try SemanticAppVersion(
            parsing: payload.tagName
        )
        guard
            payload.htmlURL.scheme?.lowercased() == "https",
            payload.htmlURL.host?.lowercased() == "github.com"
        else {
            throw AppReleaseError.unsafeReleaseURL(
                payload.htmlURL
            )
        }
        let release = AppRelease(
            tag: payload.tagName,
            version: latestVersion.description,
            name: payload.name?.nilIfBlank
                ?? payload.tagName,
            publishedAt: payload.publishedAt,
            releasePageURL: payload.htmlURL
        )
        return AppUpdateCheck(
            currentVersion: installedVersion.description,
            release: release,
            isUpdateAvailable: latestVersion > installedVersion,
            checkedAt: now
        )
    }

    private func githubMessage(
        from data: Data
    ) -> String? {
        try? JSONDecoder()
            .decode(GitHubAppErrorPayload.self, from: data)
            .message
    }

    private func diagnosticDescription(
        _ error: any Error
    ) -> String {
        if
            let localized = error as? any LocalizedError,
            let description = localized.errorDescription,
            !description.isEmpty
        {
            return description
        }
        return String(describing: error)
    }
}

private struct SemanticAppVersion:
    Comparable,
    CustomStringConvertible
{
    let major: Int
    let minor: Int
    let patch: Int

    init(
        parsing value: String
    ) throws {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let unprefixed = normalized.first == "v"
            || normalized.first == "V"
            ? String(normalized.dropFirst())
            : normalized
        let components = unprefixed.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            (1...3).contains(components.count),
            components.allSatisfy({
                !$0.isEmpty
                    && $0.allSatisfy(\.isNumber)
            })
        else {
            throw AppReleaseError.invalidVersion(value)
        }
        let numbers = try components.map { component in
            guard let value = Int(component) else {
                throw AppReleaseError.invalidVersion(
                    String(component)
                )
            }
            return value
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (
        lhs: SemanticAppVersion,
        rhs: SemanticAppVersion
    ) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

private struct GitHubAppReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let publishedAt: Date
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case htmlURL = "html_url"
    }
}

private struct GitHubAppErrorPayload: Decodable {
    let message: String
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? nil : self
    }
}
