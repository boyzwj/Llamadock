import Foundation

public enum LocalModelRemovalError:
    Error,
    Equatable,
    Sendable
{
    case unapprovedRoot(URL)
    case targetOutsideRoot(URL)
    case invalidTarget(URL, reason: String)
    case modelInUse(URL)
}

extension LocalModelRemovalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unapprovedRoot(let url):
            """
            The model directory is no longer approved by LlamaDock: \
            \(url.path)
            """
        case .targetOutsideRoot(let url):
            """
            The model is outside its approved library directory: \
            \(url.path)
            """
        case .invalidTarget(let url, let reason):
            "The model cannot be moved to Trash (\(url.path)): \(reason)"
        case .modelInUse(let url):
            """
            A running LlamaDock server is using this model or companion: \
            \(url.path)
            """
        }
    }
}

public struct LocalModelRemovalPlan:
    Equatable,
    Sendable
{
    public let targetURL: URL
    public let rootURL: URL

    public init(
        targetURL: URL,
        rootURL: URL
    ) {
        self.targetURL = targetURL.standardizedFileURL
        self.rootURL = rootURL.standardizedFileURL
    }
}

public struct LocalModelRemovalPlanner: Sendable {
    public init() {}

    public func makePlan(
        model: LocalModelFile,
        approvedRoots: [URL],
        protectedModelURLs: [URL]
    ) throws -> LocalModelRemovalPlan {
        let targetURL = model.url.standardizedFileURL
        let rootURL = model.rootURL.standardizedFileURL
        guard targetURL.isFileURL, rootURL.isFileURL else {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: "the target must be a local file"
            )
        }

        let canonicalRoot = canonicalURL(rootURL)
        let canonicalApprovedRoots = Set(
            approvedRoots.map {
                canonicalURL($0).path
            }
        )
        guard canonicalApprovedRoots.contains(canonicalRoot.path) else {
            throw LocalModelRemovalError.unapprovedRoot(rootURL)
        }
        if isSymbolicLink(targetURL) {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: """
                    symbolic links are not removable model entries
                    """
            )
        }

        let canonicalTarget = canonicalURL(targetURL)
        guard canonicalTarget != canonicalRoot else {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: "a library root cannot be removed as a model"
            )
        }
        guard
            canonicalTarget.path.hasPrefix(
                canonicalRoot.path.hasSuffix("/")
                    ? canonicalRoot.path
                    : canonicalRoot.path + "/"
            )
        else {
            throw LocalModelRemovalError
                .targetOutsideRoot(targetURL)
        }

        let protectedPaths = Set(
            protectedModelURLs.map {
                canonicalURL($0).path
            }
        )
        guard !protectedPaths.contains(canonicalTarget.path) else {
            throw LocalModelRemovalError.modelInUse(targetURL)
        }

        guard FileManager.default.fileExists(
            atPath: targetURL.path
        ) else {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: "the model file no longer exists"
            )
        }
        let values: URLResourceValues
        do {
            values = try targetURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
        } catch {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: error.localizedDescription
            )
        }
        guard values.isRegularFile == true else {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: "the target is not a regular file"
            )
        }
        guard targetURL.pathExtension.lowercased() == "gguf" else {
            throw LocalModelRemovalError.invalidTarget(
                targetURL,
                reason: "the target is not a GGUF file"
            )
        }

        return LocalModelRemovalPlan(
            targetURL: targetURL,
            rootURL: rootURL
        )
    }

    private func canonicalURL(
        _ url: URL
    ) -> URL {
        url.resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func isSymbolicLink(
        _ url: URL
    ) -> Bool {
        guard
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeSymbolicLink
    }
}

public protocol LocalModelTrashing: Sendable {
    func moveToTrash(_ url: URL) async throws
}

public actor FileManagerLocalModelTrasher:
    LocalModelTrashing
{
    private let fileManager: FileManager

    public init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    public func moveToTrash(
        _ url: URL
    ) throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(
            at: url,
            resultingItemURL: &resultingURL
        )
    }
}
