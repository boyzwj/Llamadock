import Foundation

public enum ModelDownloadProfileFactoryError:
    Error,
    Equatable,
    Sendable
{
    case jobNotCompleted(UUID)
    case invalidArtifactRoles
    case missingImportedFile(String)
}

extension ModelDownloadProfileFactoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .jobNotCompleted(let id):
            "Download job \(id.uuidString) is not completed."
        case .invalidArtifactRoles:
            "A completed download must contain one main artifact and at most one mmproj and draft artifact."
        case .missingImportedFile(let path):
            "The imported model file is missing or has the wrong size: \(path)"
        }
    }
}

public struct ModelDownloadProfileFactory:
    @unchecked Sendable
{
    private let fileManager: FileManager

    public init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    public func makeProfile(
        for job: ModelDownloadJob,
        modelsRoot: URL,
        runtimeID: String?,
        now: Date = Date()
    ) throws -> LaunchProfile {
        guard job.state == .completed else {
            throw ModelDownloadProfileFactoryError
                .jobNotCompleted(job.id)
        }

        let groups = Dictionary(
            grouping: job.files,
            by: \.artifactID
        )
        let groupsByRole = Dictionary(
            grouping: groups.values,
            by: { $0[0].role }
        )
        guard
            groupsByRole[.main]?.count == 1,
            (groupsByRole[.mmproj]?.count ?? 0) <= 1,
            (groupsByRole[.draft]?.count ?? 0) <= 1
        else {
            throw ModelDownloadProfileFactoryError
                .invalidArtifactRoles
        }

        let importedDirectory = modelsRoot.appending(
            path: job.destinationRelativeDirectory,
            directoryHint: .isDirectory
        )
        let mainPath = try primaryPath(
            for: groupsByRole[.main]![0],
            importedDirectory: importedDirectory
        )
        let mmprojPath = try groupsByRole[.mmproj]?.first
            .map {
                try primaryPath(
                    for: $0,
                    importedDirectory: importedDirectory
                )
            }
        let draftPath = try groupsByRole[.draft]?.first
            .map {
                try primaryPath(
                    for: $0,
                    importedDirectory: importedDirectory
                )
            }

        return LaunchProfile(
            name: "\(job.displayName) Default",
            model: ModelPaths(
                mainPath: mainPath,
                mmprojPath: mmprojPath,
                draftPath: draftPath
            ),
            runtimeSelection: RuntimeSelection(
                policy: runtimeID == nil
                    ? .activeManaged
                    : .specific,
                runtimeID: runtimeID
            ),
            server: ServerOptions(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func primaryPath(
        for files: [ModelDownloadFile],
        importedDirectory: URL
    ) throws -> String {
        guard
            let primary = files.sorted(
                by: {
                    $0.repositoryPath.localizedStandardCompare(
                        $1.repositoryPath
                    ) == .orderedAscending
                }
            ).first
        else {
            throw ModelDownloadProfileFactoryError
                .invalidArtifactRoles
        }
        let url = importedDirectory.appending(
            path: primary.repositoryPath,
            directoryHint: .notDirectory
        )
        guard
            fileManager.fileExists(atPath: url.path),
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            ),
            let size = (attributes[.size] as? NSNumber)?
                .int64Value,
            size == primary.expectedSize,
            attributes[.type] as? FileAttributeType
                == .typeRegular
        else {
            throw ModelDownloadProfileFactoryError
                .missingImportedFile(primary.repositoryPath)
        }
        return url.standardizedFileURL.path
    }
}
