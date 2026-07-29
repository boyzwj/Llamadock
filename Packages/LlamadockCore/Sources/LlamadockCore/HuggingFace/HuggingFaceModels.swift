import Foundation

public struct HuggingFaceRepositoryReference:
    Equatable,
    Hashable,
    Sendable
{
    public let repositoryID: String
    public let revision: String
    public let quantization: String?

    public init(
        repositoryID: String,
        revision: String = "main",
        quantization: String? = nil
    ) {
        self.repositoryID = repositoryID
        self.revision = revision
        self.quantization = quantization
    }
}

public enum HuggingFaceGatedStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case none
    case automatic
    case manual
    case gated

    public var requiresAuthentication: Bool {
        self != .none
    }
}

public struct HuggingFaceRepository:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let downloads: Int
    public let likes: Int
    public let lastModified: Date?
    public let gated: HuggingFaceGatedStatus
    public let isPrivate: Bool
    public let pipelineTag: String?
    public let tags: [String]

    public init(
        id: String,
        downloads: Int,
        likes: Int,
        lastModified: Date?,
        gated: HuggingFaceGatedStatus,
        isPrivate: Bool,
        pipelineTag: String?,
        tags: [String]
    ) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.gated = gated
        self.isPrivate = isPrivate
        self.pipelineTag = pipelineTag
        self.tags = tags
    }
}

public enum HuggingFaceTreeEntryKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case file
    case directory
}

public struct HuggingFaceRepositoryFile:
    Equatable,
    Identifiable,
    Sendable
{
    public let path: String
    public let size: Int64
    public let gitOID: String?
    public let lfsOID: String?

    public var id: String {
        path
    }

    public var expectedSHA256: String? {
        guard
            let lfsOID,
            lfsOID.count == 64,
            lfsOID.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return lfsOID.lowercased()
    }

    public init(
        path: String,
        size: Int64,
        gitOID: String?,
        lfsOID: String?
    ) {
        self.path = path
        self.size = size
        self.gitOID = gitOID
        self.lfsOID = lfsOID
    }
}

public enum HuggingFaceGGUFRole:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case main
    case mmproj
    case draft
}

public struct HuggingFaceSplitPart:
    Codable,
    Equatable,
    Sendable
{
    public let index: Int
    public let count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

public struct HuggingFaceGGUFFile:
    Equatable,
    Identifiable,
    Sendable
{
    public let repositoryFile: HuggingFaceRepositoryFile
    public let role: HuggingFaceGGUFRole
    public let quantization: String?
    public let split: HuggingFaceSplitPart?

    public var id: String {
        repositoryFile.id
    }

    public init(
        repositoryFile: HuggingFaceRepositoryFile,
        role: HuggingFaceGGUFRole,
        quantization: String?,
        split: HuggingFaceSplitPart?
    ) {
        self.repositoryFile = repositoryFile
        self.role = role
        self.quantization = quantization
        self.split = split
    }
}

public struct HuggingFaceGGUFArtifact:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let displayName: String
    public let role: HuggingFaceGGUFRole
    public let quantization: String?
    public let files: [HuggingFaceGGUFFile]
    public let totalSize: Int64
    public let isComplete: Bool

    public init(
        id: String,
        displayName: String,
        role: HuggingFaceGGUFRole,
        quantization: String?,
        files: [HuggingFaceGGUFFile],
        totalSize: Int64,
        isComplete: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.quantization = quantization
        self.files = files
        self.totalSize = totalSize
        self.isComplete = isComplete
    }
}

public struct HuggingFaceRepositoryCatalog:
    Equatable,
    Sendable
{
    public let artifacts: [HuggingFaceGGUFArtifact]
    public let ignoredPaths: [String]

    public init(
        artifacts: [HuggingFaceGGUFArtifact],
        ignoredPaths: [String]
    ) {
        self.artifacts = artifacts
        self.ignoredPaths = ignoredPaths
    }
}
