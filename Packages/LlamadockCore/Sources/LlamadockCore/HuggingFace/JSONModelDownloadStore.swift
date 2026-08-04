import Foundation

public enum ModelDownloadStoreError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedSchemaVersion(Int)
    case invalidJob(id: UUID, reason: String)
}

extension ModelDownloadStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported download state schema version: \(version)."
        case .invalidJob(let id, let reason):
            "Invalid download job \(id.uuidString): \(reason)."
        }
    }
}

public protocol ModelDownloadStoring: Sendable {
    func loadJobs() async throws -> [ModelDownloadJob]
    func saveJobs(_ jobs: [ModelDownloadJob]) async throws
}

public actor JSONModelDownloadStore: ModelDownloadStoring {
    public static let currentSchemaVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
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

    public func loadJobs() throws -> [ModelDownloadJob] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let document = try decoder.decode(
            ModelDownloadStateDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard
            document.schemaVersion == Self.currentSchemaVersion
        else {
            throw ModelDownloadStoreError
                .unsupportedSchemaVersion(
                    document.schemaVersion
                )
        }
        try validate(document.jobs)
        return document.jobs.sorted(by: compareJobs)
    }

    public func saveJobs(
        _ jobs: [ModelDownloadJob]
    ) throws {
        try validate(jobs)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = ModelDownloadStateDocument(
            schemaVersion: Self.currentSchemaVersion,
            jobs: jobs.sorted(by: compareJobs)
        )
        try atomicallyWrite(encoder.encode(document))
    }

    private func validate(
        _ jobs: [ModelDownloadJob]
    ) throws {
        guard Set(jobs.map(\.id)).count == jobs.count else {
            let duplicate = jobs.first { job in
                jobs.filter { $0.id == job.id }.count > 1
            }
            throw ModelDownloadStoreError.invalidJob(
                id: duplicate?.id ?? UUID(),
                reason: "duplicate job ID"
            )
        }

        for job in jobs {
            guard
                job.schemaVersion
                    == ModelDownloadJob.currentSchemaVersion
            else {
                throw ModelDownloadStoreError.invalidJob(
                    id: job.id,
                    reason: "unsupported job schema"
                )
            }
            guard
                isSafeRelativePath(
                    job.destinationRelativeDirectory
                ),
                job.resolvedRevision.map(isSafeRevision) ?? true,
                !job.files.isEmpty,
                Set(job.files.map(\.id)).count
                    == job.files.count
            else {
                throw ModelDownloadStoreError.invalidJob(
                    id: job.id,
                    reason: "unsafe destination or duplicate/empty files"
                )
            }
            for file in job.files {
                let restartReasonIsValid: Bool
                if let reason = file.restartReason {
                    restartReasonIsValid = [
                        "checksumMismatch",
                        "invalidGGUF",
                    ].contains(reason)
                } else {
                    restartReasonIsValid = true
                }
                guard
                    isSafeRelativePath(file.repositoryPath),
                    file.expectedSize > 0,
                    file.receivedBytes >= 0,
                    file.receivedBytes <= file.expectedSize,
                    isValidSHA256(file.expectedSHA256),
                    restartReasonIsValid
                else {
                    throw ModelDownloadStoreError.invalidJob(
                        id: job.id,
                        reason: "invalid file metadata"
                    )
                }
            }
        }
    }

    private func compareJobs(
        _ lhs: ModelDownloadJob,
        _ rhs: ModelDownloadJob
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func atomicallyWrite(
        _ data: Data
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".state.\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try data.write(
                to: temporaryURL,
                options: .withoutOverwriting
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: fileURL
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private struct ModelDownloadStateDocument: Codable {
    let schemaVersion: Int
    let jobs: [ModelDownloadJob]
}

private func isSafeRelativePath(
    _ path: String
) -> Bool {
    guard !path.hasPrefix("/") else {
        return false
    }
    let segments = path.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    return !segments.isEmpty
        && segments.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !$0.contains("\\")
        }
}

private func isSafeRevision(
    _ value: String
) -> Bool {
    !value.isEmpty
        && value != "."
        && value != ".."
        && value.count <= 256
        && !value.contains("\\")
        && !value.contains(where: \.isNewline)
}

private func isValidSHA256(
    _ value: String?
) -> Bool {
    guard let value else {
        return true
    }
    return value.count == 64
        && value.allSatisfy(\.isHexDigit)
}
