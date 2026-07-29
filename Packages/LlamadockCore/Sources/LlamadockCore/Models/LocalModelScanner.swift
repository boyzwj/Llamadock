import CryptoKit
import Foundation

public enum LocalModelRole:
    String,
    Codable,
    Equatable,
    Sendable
{
    case main
    case mmproj
    case draft
    case adapter
    case auxiliary
}

public enum LocalModelValidation:
    Equatable,
    Sendable
{
    case valid
    case invalid(reason: String)
}

public struct LocalModelFile:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let url: URL
    public let rootURL: URL
    public let fileSize: UInt64
    public let modificationDate: Date?
    public let role: LocalModelRole
    public let metadata: GGUFMetadata?
    public let validation: LocalModelValidation

    public init(
        id: String,
        url: URL,
        rootURL: URL,
        fileSize: UInt64,
        modificationDate: Date?,
        role: LocalModelRole,
        metadata: GGUFMetadata?,
        validation: LocalModelValidation
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.rootURL = rootURL.standardizedFileURL
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.role = role
        self.metadata = metadata
        self.validation = validation
    }

    public var displayName: String {
        metadata?.name
            ?? url.deletingPathExtension().lastPathComponent
    }
}

public struct LocalModelScanIssue:
    Equatable,
    Sendable
{
    public let rootURL: URL
    public let reason: String

    public init(
        rootURL: URL,
        reason: String
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.reason = reason
    }
}

public struct LocalModelScanSnapshot:
    Equatable,
    Sendable
{
    public let roots: [URL]
    public let models: [LocalModelFile]
    public let issues: [LocalModelScanIssue]
    public let scannedAt: Date

    public init(
        roots: [URL],
        models: [LocalModelFile],
        issues: [LocalModelScanIssue],
        scannedAt: Date
    ) {
        self.roots = roots.map(\.standardizedFileURL)
        self.models = models
        self.issues = issues
        self.scannedAt = scannedAt
    }
}

public actor LocalModelScanner {
    private let metadataReader: GGUFMetadataReader
    private let fileManager: FileManager

    public init(
        metadataReader: GGUFMetadataReader =
            GGUFMetadataReader(),
        fileManager: FileManager = .default
    ) {
        self.metadataReader = metadataReader
        self.fileManager = fileManager
    }

    public func scan(
        roots: [URL],
        now: Date = Date()
    ) async throws -> LocalModelScanSnapshot {
        let uniqueRoots = uniqueStandardizedURLs(roots)
        var modelsByID: [String: LocalModelFile] = [:]
        var issues: [LocalModelScanIssue] = []

        for root in uniqueRoots {
            try Task.checkCancellation()
            let rootValues: URLResourceValues
            do {
                rootValues = try root.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isReadableKey,
                    ]
                )
            } catch {
                issues.append(
                    LocalModelScanIssue(
                        rootURL: root,
                        reason: error.localizedDescription
                    )
                )
                continue
            }
            guard
                rootValues.isDirectory == true,
                rootValues.isReadable != false
            else {
                issues.append(
                    LocalModelScanIssue(
                        rootURL: root,
                        reason: "The model root is not a readable directory."
                    )
                )
                continue
            }

            try scanContents(
                of: root,
                modelsByID: &modelsByID,
                issues: &issues
            )
        }

        let models = modelsByID.values.sorted {
            let nameComparison = $0.displayName
                .localizedStandardCompare($1.displayName)
            if nameComparison == .orderedSame {
                return $0.url.path < $1.url.path
            }
            return nameComparison == .orderedAscending
        }
        return LocalModelScanSnapshot(
            roots: uniqueRoots,
            models: models,
            issues: issues,
            scannedAt: now
        )
    }

    private func scanContents(
        of root: URL,
        modelsByID: inout [String: LocalModelFile],
        issues: inout [LocalModelScanIssue]
    ) throws {
        let resolvedRoot = root
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var enumerationIssues: [LocalModelScanIssue] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants,
            ],
            errorHandler: { url, error in
                enumerationIssues.append(
                    LocalModelScanIssue(
                        rootURL: url,
                        reason: error.localizedDescription
                    )
                )
                return true
            }
        ) else {
            issues.append(
                LocalModelScanIssue(
                    rootURL: root,
                    reason: "The model directory could not be enumerated."
                )
            )
            return
        }

        for case let candidate as URL in enumerator {
            if Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(
                    forKeys: Set(resourceKeys)
                )
            } catch {
                issues.append(
                    LocalModelScanIssue(
                        rootURL: candidate,
                        reason: error.localizedDescription
                    )
                )
                continue
            }

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isDirectory == true {
                continue
            }
            guard
                values.isRegularFile == true,
                candidate.pathExtension.lowercased() == "gguf",
                !isTemporaryFile(candidate)
            else {
                continue
            }

            let resolvedCandidate = candidate
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard
                resolvedCandidate.path.hasPrefix(
                    resolvedRoot.path + "/"
                )
            else {
                continue
            }

            let fileSize = UInt64(max(values.fileSize ?? 0, 0))
            let id = modelID(
                url: candidate,
                fileSize: fileSize,
                modificationDate: values.contentModificationDate,
                volumeIdentifier: values.volumeIdentifier,
                fileIdentifier: values.fileResourceIdentifier
            )
            guard modelsByID[id] == nil else {
                continue
            }

            let metadata: GGUFMetadata?
            let validation: LocalModelValidation
            do {
                metadata = try metadataReader.read(
                    from: candidate
                )
                validation = .valid
            } catch {
                metadata = nil
                validation = .invalid(
                    reason: diagnosticDescription(error)
                )
            }

            modelsByID[id] = LocalModelFile(
                id: id,
                url: candidate,
                rootURL: root,
                fileSize: fileSize,
                modificationDate: values.contentModificationDate,
                role: role(
                    for: candidate,
                    metadata: metadata
                ),
                metadata: metadata,
                validation: validation
            )
        }
        issues.append(contentsOf: enumerationIssues)
    }

    private var resourceKeys: [URLResourceKey] {
        [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
        ]
    }

    private func uniqueStandardizedURLs(
        _ urls: [URL]
    ) -> [URL] {
        var paths = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return paths.insert(standardized.path).inserted
                ? standardized
                : nil
        }
    }

    private func isTemporaryFile(
        _ url: URL
    ) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".part")
            || name.hasSuffix(".tmp")
            || name.hasSuffix(".download")
    }

    private func role(
        for url: URL,
        metadata: GGUFMetadata?
    ) -> LocalModelRole {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("mmproj-")
            || metadata?.modelKind == "mmproj"
        {
            return .mmproj
        }
        if name.hasPrefix("mtp-")
            || name.contains("-draft-")
        {
            return .draft
        }
        switch metadata?.modelKind {
        case "adapter":
            return .adapter
        case "imatrix":
            return .auxiliary
        default:
            return .main
        }
    }

    private func modelID(
        url: URL,
        fileSize: UInt64,
        modificationDate: Date?,
        volumeIdentifier: Any?,
        fileIdentifier: Any?
    ) -> String {
        let material: String
        if let volumeIdentifier, let fileIdentifier {
            material = [
                "resource",
                stableDescription(volumeIdentifier),
                stableDescription(fileIdentifier),
            ].joined(separator: "\u{0}")
        } else {
            material = [
                "fallback",
                url.standardizedFileURL.path,
                String(fileSize),
                modificationDate.map {
                    String($0.timeIntervalSinceReferenceDate)
                } ?? "",
            ].joined(separator: "\u{0}")
        }
        let digest = SHA256.hash(
            data: Data(material.utf8)
        )
        return "model:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func stableDescription(
        _ value: Any
    ) -> String {
        if let data = value as? Data {
            return data.base64EncodedString()
        }
        if let data = value as? NSData {
            return (data as Data).base64EncodedString()
        }
        return String(reflecting: value)
    }

    private func diagnosticDescription(
        _ error: Error
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
