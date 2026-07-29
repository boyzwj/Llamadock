import CryptoKit
import Foundation

public enum RuntimeArchiveVerificationError:
    Error,
    Equatable,
    Sendable
{
    case notRegularFile(URL)
    case sizeMismatch(expected: Int64, actual: Int64)
    case unsupportedDigest(String)
    case invalidDigest(String)
    case digestMismatch(expected: String, actual: String)
}

extension RuntimeArchiveVerificationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let url):
            "The downloaded runtime archive is not a regular file: \(url.path)"
        case .sizeMismatch(let expected, let actual):
            "The runtime archive expected \(expected) bytes but has \(actual)."
        case .unsupportedDigest(let digest):
            "The runtime archive uses an unsupported digest: \(digest)"
        case .invalidDigest(let digest):
            "The runtime archive digest is malformed: \(digest)"
        case .digestMismatch(let expected, let actual):
            "The runtime archive SHA-256 mismatch: expected \(expected), got \(actual)."
        }
    }
}

public struct RuntimeArchiveVerification: Equatable, Sendable {
    public let byteCount: Int64
    public let sha256: String

    public init(
        byteCount: Int64,
        sha256: String
    ) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct RuntimeArchiveVerifier: Sendable {
    public init() {}

    public func verify(
        archiveURL: URL,
        asset: GitHubRuntimeReleaseAsset
    ) throws -> RuntimeArchiveVerification {
        let values = try archiveURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw RuntimeArchiveVerificationError.notRegularFile(
                archiveURL
            )
        }

        let byteCount = Int64(values.fileSize ?? -1)
        guard byteCount == asset.size else {
            throw RuntimeArchiveVerificationError.sizeMismatch(
                expected: asset.size,
                actual: byteCount
            )
        }

        let actualDigest = try sha256(of: archiveURL)
        if let digest = asset.digest {
            let expectedDigest = try parseSHA256(digest)
            guard expectedDigest == actualDigest else {
                throw RuntimeArchiveVerificationError.digestMismatch(
                    expected: expectedDigest,
                    actual: actualDigest
                )
            }
        }

        return RuntimeArchiveVerification(
            byteCount: byteCount,
            sha256: actualDigest
        )
    }

    private func parseSHA256(
        _ digest: String
    ) throws -> String {
        let components = digest.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            components.count == 2,
            components[0].lowercased() == "sha256"
        else {
            throw RuntimeArchiveVerificationError.unsupportedDigest(
                digest
            )
        }

        let value = components[1].lowercased()
        guard
            value.count == 64,
            value.allSatisfy(\.isHexDigit)
        else {
            throw RuntimeArchiveVerificationError.invalidDigest(
                digest
            )
        }
        return value
    }

    private func sha256(
        of url: URL
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576),
            !data.isEmpty
        {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
