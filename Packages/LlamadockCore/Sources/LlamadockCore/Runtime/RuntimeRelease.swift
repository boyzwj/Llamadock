import Foundation

public enum RuntimeReleaseError: Error, Equatable, Sendable {
    case invalidTag(String)
    case noCompatibleMacOSAppleSiliconAsset
    case invalidPayload(String)
    case httpStatus(Int, message: String?)
    case notModifiedWithoutCache
    case transport(String)
}

extension RuntimeReleaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTag(let tag):
            "The llama.cpp release tag is invalid: \(tag)"
        case .noCompatibleMacOSAppleSiliconAsset:
            "The release does not contain a compatible macOS Apple Silicon archive."
        case .invalidPayload(let reason):
            "The GitHub release response is invalid: \(reason)"
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                "GitHub returned HTTP \(statusCode): \(message)"
            } else {
                "GitHub returned HTTP \(statusCode)."
            }
        case .notModifiedWithoutCache:
            "GitHub returned not modified, but no validated cached release exists."
        case .transport(let reason):
            "The GitHub release request failed: \(reason)"
        }
    }
}

public struct LlamaBuildTag: Codable, Equatable, Sendable {
    public let tag: String
    public let build: Int

    public init(tag: String, build: Int) {
        self.tag = tag
        self.build = build
    }

    public init(parsing tag: String) throws {
        guard
            tag.first == "b",
            tag.count > 1,
            tag.dropFirst().allSatisfy(\.isNumber),
            let build = Int(tag.dropFirst()),
            build > 0
        else {
            throw RuntimeReleaseError.invalidTag(tag)
        }

        self.tag = tag
        self.build = build
    }

    public init?(
        parsingVersionOutput output: String
    ) {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                trimmed.lowercased().hasPrefix("version:")
            else {
                continue
            }

            let value = trimmed.dropFirst("version:".count)
                .drop(while: \.isWhitespace)
            let digits = value.prefix(while: \.isNumber)
            guard
                !digits.isEmpty,
                let parsed = try? Self(
                    parsing: "b\(digits)"
                )
            else {
                return nil
            }
            self = parsed
            return
        }
        return nil
    }
}

public struct GitHubRuntimeReleaseAsset: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let downloadURL: URL
    public let size: Int64
    public let contentType: String?
    public let digest: String?

    public init(
        id: Int64,
        name: String,
        downloadURL: URL,
        size: Int64,
        contentType: String?,
        digest: String?
    ) {
        self.id = id
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.contentType = contentType
        self.digest = digest
    }
}

public struct ManagedRuntimeRelease: Codable, Equatable, Sendable {
    public let buildTag: LlamaBuildTag
    public let publishedAt: Date
    public let asset: GitHubRuntimeReleaseAsset

    public init(
        buildTag: LlamaBuildTag,
        publishedAt: Date,
        asset: GitHubRuntimeReleaseAsset
    ) {
        self.buildTag = buildTag
        self.publishedAt = publishedAt
        self.asset = asset
    }

    public var tag: String {
        buildTag.tag
    }

    public var build: Int {
        buildTag.build
    }
}

public struct CachedRuntimeRelease: Codable, Equatable, Sendable {
    public let release: ManagedRuntimeRelease
    public let etag: String?
    public let fetchedAt: Date

    public init(
        release: ManagedRuntimeRelease,
        etag: String?,
        fetchedAt: Date
    ) {
        self.release = release
        self.etag = etag
        self.fetchedAt = fetchedAt
    }
}

public protocol RuntimeReleaseCaching: Sendable {
    func load() async throws -> CachedRuntimeRelease?
    func save(_ entry: CachedRuntimeRelease) async throws
}

public actor EmptyRuntimeReleaseCache: RuntimeReleaseCaching {
    public init() {}

    public func load() -> CachedRuntimeRelease? {
        nil
    }

    public func save(_ entry: CachedRuntimeRelease) {}
}

public enum RuntimeReleaseCheckSource: Equatable, Sendable {
    case network
    case notModifiedCache
    case staleCache
}

public struct RuntimeReleaseCheck: Equatable, Sendable {
    public let release: ManagedRuntimeRelease
    public let source: RuntimeReleaseCheckSource
    public let fetchedAt: Date
    public let warning: String?

    public init(
        release: ManagedRuntimeRelease,
        source: RuntimeReleaseCheckSource,
        fetchedAt: Date,
        warning: String?
    ) {
        self.release = release
        self.source = source
        self.fetchedAt = fetchedAt
        self.warning = warning
    }
}

public protocol RuntimeReleaseChecking: Sendable {
    func checkLatest(
        now: Date
    ) async throws -> RuntimeReleaseCheck
}

public struct GitHubRuntimeAssetSelector: Sendable {
    public init() {}

    public func selectMacOSAppleSiliconAsset(
        from assets: [GitHubRuntimeReleaseAsset]
    ) throws -> GitHubRuntimeReleaseAsset {
        let candidates = assets.compactMap { asset -> Candidate? in
            let name = asset.name.lowercased()
            guard
                asset.downloadURL.scheme?.lowercased() == "https",
                isArchive(name),
                containsMacOSToken(name),
                containsAppleSiliconToken(name),
                !containsIntelOnlyToken(name)
            else {
                return nil
            }

            var score = 0
            score += name.contains("macos") ? 40 : 20
            score += name.contains("arm64") ? 40 : 30
            score += name.contains("-bin-") ? 10 : 0
            score += name.hasSuffix(".tar.gz") ? 5 : 0
            return Candidate(asset: asset, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.asset.name < rhs.asset.name
            }
            return lhs.score > rhs.score
        }

        guard let selected = candidates.first?.asset else {
            throw RuntimeReleaseError
                .noCompatibleMacOSAppleSiliconAsset
        }
        return selected
    }

    private func isArchive(_ name: String) -> Bool {
        name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tgz")
            || name.hasSuffix(".zip")
    }

    private func containsMacOSToken(_ name: String) -> Bool {
        name.contains("macos")
            || name.contains("darwin")
            || name.contains("osx")
    }

    private func containsAppleSiliconToken(_ name: String) -> Bool {
        name.contains("arm64")
            || name.contains("aarch64")
            || name.contains("universal")
    }

    private func containsIntelOnlyToken(_ name: String) -> Bool {
        name.contains("x86_64")
            || name.contains("amd64")
            || name.contains("-x64")
    }

    private struct Candidate {
        let asset: GitHubRuntimeReleaseAsset
        let score: Int
    }
}
