import Foundation

public enum ModelHubSource:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case huggingFace
    case modelScope

    public var storageDirectoryComponent: String {
        switch self {
        case .huggingFace:
            "huggingface"
        case .modelScope:
            "modelscope"
        }
    }
}

public enum ModelDownloadState:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case queued
    case resolving
    case downloading
    case paused
    case verifying
    case importing
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case
            .queued,
            .resolving,
            .downloading,
            .paused,
            .verifying,
            .importing:
            false
        }
    }
}

public struct ModelDownloadRequestFile:
    Equatable,
    Sendable
{
    public let artifactID: String
    public let artifactDisplayName: String
    public let role: HuggingFaceGGUFRole
    public let repositoryPath: String
    public let expectedSize: Int64
    public let expectedSHA256: String?

    public init(
        artifactID: String,
        artifactDisplayName: String,
        role: HuggingFaceGGUFRole,
        repositoryPath: String,
        expectedSize: Int64,
        expectedSHA256: String?
    ) {
        self.artifactID = artifactID
        self.artifactDisplayName = artifactDisplayName
        self.role = role
        self.repositoryPath = repositoryPath
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
    }
}

public struct ModelDownloadRequest:
    Equatable,
    Sendable
{
    public let source: ModelHubSource
    public let reference: HuggingFaceRepositoryReference
    public let displayName: String
    public let quantization: String?
    public let files: [ModelDownloadRequestFile]

    public init(
        source: ModelHubSource = .huggingFace,
        reference: HuggingFaceRepositoryReference,
        displayName: String,
        quantization: String?,
        files: [ModelDownloadRequestFile]
    ) {
        self.source = source
        self.reference = reference
        self.displayName = displayName
        self.quantization = quantization
        self.files = files
    }
}

public struct ModelDownloadFile:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let artifactID: String
    public let artifactDisplayName: String
    public let role: HuggingFaceGGUFRole
    public let repositoryPath: String
    public let expectedSize: Int64
    public let expectedSHA256: String?
    public var receivedBytes: Int64
    public var etag: String?
    public var isVerified: Bool
    public var restartReason: String?

    public var id: String {
        "\(artifactID):\(repositoryPath)"
    }

    public init(
        artifactID: String,
        artifactDisplayName: String,
        role: HuggingFaceGGUFRole,
        repositoryPath: String,
        expectedSize: Int64,
        expectedSHA256: String?,
        receivedBytes: Int64 = 0,
        etag: String? = nil,
        isVerified: Bool = false,
        restartReason: String? = nil
    ) {
        self.artifactID = artifactID
        self.artifactDisplayName = artifactDisplayName
        self.role = role
        self.repositoryPath = repositoryPath
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.receivedBytes = receivedBytes
        self.etag = etag
        self.isVerified = isVerified
        self.restartReason = restartReason
    }
}

public struct ModelDownloadJob:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let source: ModelHubSource
    public let repositoryID: String
    public let revision: String
    public var resolvedRevision: String?
    public let displayName: String
    public let quantization: String?
    public let destinationRelativeDirectory: String
    public var files: [ModelDownloadFile]
    public var state: ModelDownloadState
    public var error: String?
    public let createdAt: Date
    public var updatedAt: Date

    public var expectedBytes: Int64 {
        saturatingSum(files.map(\.expectedSize))
    }

    public var receivedBytes: Int64 {
        saturatingSum(files.map(\.receivedBytes))
    }

    public var progress: Double {
        guard expectedBytes > 0 else {
            return 0
        }
        return min(
            max(
                Double(receivedBytes)
                    / Double(expectedBytes),
                0
            ),
            1
        )
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID,
        source: ModelHubSource = .huggingFace,
        repositoryID: String,
        revision: String,
        resolvedRevision: String? = nil,
        displayName: String,
        quantization: String?,
        destinationRelativeDirectory: String,
        files: [ModelDownloadFile],
        state: ModelDownloadState,
        error: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.source = source
        self.repositoryID = repositoryID
        self.revision = revision
        self.resolvedRevision = resolvedRevision
        self.displayName = displayName
        self.quantization = quantization
        self.destinationRelativeDirectory =
            destinationRelativeDirectory
        self.files = files
        self.state = state
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case source
        case repositoryID
        case revision
        case resolvedRevision
        case displayName
        case quantization
        case destinationRelativeDirectory
        case files
        case state
        case error
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decodeIfPresent(
            ModelHubSource.self,
            forKey: .source
        ) ?? .huggingFace
        repositoryID = try container.decode(
            String.self,
            forKey: .repositoryID
        )
        revision = try container.decode(
            String.self,
            forKey: .revision
        )
        resolvedRevision = try container.decodeIfPresent(
            String.self,
            forKey: .resolvedRevision
        )
        displayName = try container.decode(
            String.self,
            forKey: .displayName
        )
        quantization = try container.decodeIfPresent(
            String.self,
            forKey: .quantization
        )
        destinationRelativeDirectory = try container.decode(
            String.self,
            forKey: .destinationRelativeDirectory
        )
        files = try container.decode(
            [ModelDownloadFile].self,
            forKey: .files
        )
        state = try container.decode(
            ModelDownloadState.self,
            forKey: .state
        )
        error = try container.decodeIfPresent(
            String.self,
            forKey: .error
        )
        createdAt = try container.decode(
            Date.self,
            forKey: .createdAt
        )
        updatedAt = try container.decode(
            Date.self,
            forKey: .updatedAt
        )
    }
}

public struct ModelDownloadSnapshot:
    Equatable,
    Sendable
{
    public let jobs: [ModelDownloadJob]
    public let activeJobID: UUID?

    public init(
        jobs: [ModelDownloadJob] = [],
        activeJobID: UUID? = nil
    ) {
        self.jobs = jobs
        self.activeJobID = activeJobID
    }
}

private func saturatingSum(
    _ values: [Int64]
) -> Int64 {
    values.reduce(0) { partial, value in
        let sum = partial.addingReportingOverflow(
            max(value, 0)
        )
        return sum.overflow ? Int64.max : sum.partialValue
    }
}
