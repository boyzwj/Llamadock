import Foundation

public enum RuntimeArchiveError: Error, Equatable, Sendable {
    case emptyManifest
    case malformedListingLine(String)
    case unsupportedEntryType(Character)
    case unsafePath(String)
    case duplicatePath(String)
    case unsafeLink(path: String, target: String)
    case excessiveDepth(path: String, maximum: Int)
    case tooManyEntries(count: Int, maximum: Int)
    case destinationAlreadyExists(URL)
    case toolFailed(stage: String, reason: String)
    case extractedLinkEscapes(path: String)
}

extension RuntimeArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyManifest:
            "The runtime archive is empty."
        case .malformedListingLine(let line):
            "The archive listing contains an unrecognized line: \(line)"
        case .unsupportedEntryType(let type):
            "The archive contains an unsupported entry type: \(type)"
        case .unsafePath(let path):
            "The archive contains an unsafe path: \(path)"
        case .duplicatePath(let path):
            "The archive contains a duplicate path: \(path)"
        case .unsafeLink(let path, let target):
            "The archive link escapes its root: \(path) -> \(target)"
        case .excessiveDepth(let path, let maximum):
            "The archive path exceeds depth \(maximum): \(path)"
        case .tooManyEntries(let count, let maximum):
            "The archive has \(count) entries; the maximum is \(maximum)."
        case .destinationAlreadyExists(let url):
            "The extraction destination already exists: \(url.path)"
        case .toolFailed(let stage, let reason):
            "Archive \(stage) failed: \(reason)"
        case .extractedLinkEscapes(let path):
            "An extracted link resolves outside the transaction directory: \(path)"
        }
    }
}

public enum RuntimeArchiveEntryKind: Equatable, Sendable {
    case file
    case directory
    case symbolicLink(target: String)
    case hardLink(target: String)
}

public struct RuntimeArchiveEntry: Equatable, Sendable {
    public let path: String
    public let kind: RuntimeArchiveEntryKind

    public init(
        path: String,
        kind: RuntimeArchiveEntryKind
    ) {
        self.path = path
        self.kind = kind
    }
}

public struct RuntimeArchiveManifestValidator: Sendable {
    private let maximumEntries: Int
    private let maximumDepth: Int

    public init(
        maximumEntries: Int = 20_000,
        maximumDepth: Int = 16
    ) {
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
    }

    public func validate(
        _ entries: [RuntimeArchiveEntry]
    ) throws {
        guard !entries.isEmpty else {
            throw RuntimeArchiveError.emptyManifest
        }
        guard entries.count <= maximumEntries else {
            throw RuntimeArchiveError.tooManyEntries(
                count: entries.count,
                maximum: maximumEntries
            )
        }

        var paths = Set<String>()
        for entry in entries {
            let components = try validatedComponents(
                of: entry.path
            )
            guard components.count <= maximumDepth else {
                throw RuntimeArchiveError.excessiveDepth(
                    path: entry.path,
                    maximum: maximumDepth
                )
            }

            let normalizedPath = components.joined(separator: "/")
            guard paths.insert(normalizedPath).inserted else {
                throw RuntimeArchiveError.duplicatePath(
                    entry.path
                )
            }

            switch entry.kind {
            case .file, .directory:
                break
            case .symbolicLink(let target):
                try validateSymbolicLink(
                    entryPathComponents: components,
                    path: entry.path,
                    target: target
                )
            case .hardLink(let target):
                do {
                    _ = try validatedComponents(of: target)
                } catch {
                    throw RuntimeArchiveError.unsafeLink(
                        path: entry.path,
                        target: target
                    )
                }
            }
        }
    }

    private func validatedComponents(
        of path: String
    ) throws -> [Substring] {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.contains("\0"),
            !path.contains("\n"),
            !path.contains("\r")
        else {
            throw RuntimeArchiveError.unsafePath(path)
        }

        let rawComponents = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        var components: [Substring] = []
        for (index, component) in rawComponents.enumerated() {
            if component.isEmpty {
                let isTrailingDirectorySeparator =
                    index == rawComponents.count - 1
                guard isTrailingDirectorySeparator else {
                    throw RuntimeArchiveError.unsafePath(path)
                }
                continue
            }
            if component == "." {
                continue
            }
            guard
                component != "..",
                !component.hasSuffix(":")
            else {
                throw RuntimeArchiveError.unsafePath(path)
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            throw RuntimeArchiveError.unsafePath(path)
        }
        return components
    }

    private func validateSymbolicLink(
        entryPathComponents: [Substring],
        path: String,
        target: String
    ) throws {
        guard
            !target.isEmpty,
            !target.hasPrefix("/"),
            !target.contains("\0"),
            !target.contains("\n"),
            !target.contains("\r")
        else {
            throw RuntimeArchiveError.unsafeLink(
                path: path,
                target: target
            )
        }

        var resolved = entryPathComponents.dropLast().map(String.init)
        for component in target.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !resolved.isEmpty else {
                    throw RuntimeArchiveError.unsafeLink(
                        path: path,
                        target: target
                    )
                }
                resolved.removeLast()
            } else {
                resolved.append(String(component))
            }
        }
        guard !resolved.isEmpty else {
            throw RuntimeArchiveError.unsafeLink(
                path: path,
                target: target
            )
        }
    }
}

public struct BSDTarVerboseListingParser: Sendable {
    public init() {}

    public func parse(
        _ output: String
    ) throws -> [RuntimeArchiveEntry] {
        try output
            .split(
                whereSeparator: \.isNewline
            )
            .map(parseLine)
    }

    private func parseLine(
        _ line: Substring
    ) throws -> RuntimeArchiveEntry {
        let columns = line.split(
            maxSplits: 8,
            whereSeparator: \.isWhitespace
        )
        guard
            columns.count == 9,
            let type = columns[0].first
        else {
            throw RuntimeArchiveError.malformedListingLine(
                String(line)
            )
        }

        let pathAndTarget = String(columns[8])
        switch type {
        case "d":
            return RuntimeArchiveEntry(
                path: pathAndTarget,
                kind: .directory
            )
        case "-":
            return RuntimeArchiveEntry(
                path: pathAndTarget,
                kind: .file
            )
        case "l":
            let pair = try splitLink(
                pathAndTarget,
                separator: " -> ",
                originalLine: line
            )
            return RuntimeArchiveEntry(
                path: pair.path,
                kind: .symbolicLink(target: pair.target)
            )
        case "h":
            let pair = try splitLink(
                pathAndTarget,
                separator: " link to ",
                originalLine: line
            )
            return RuntimeArchiveEntry(
                path: pair.path,
                kind: .hardLink(target: pair.target)
            )
        default:
            throw RuntimeArchiveError.unsupportedEntryType(type)
        }
    }

    private func splitLink(
        _ value: String,
        separator: String,
        originalLine: Substring
    ) throws -> (path: String, target: String) {
        guard let range = value.range(
            of: separator,
            options: .backwards
        ) else {
            throw RuntimeArchiveError.malformedListingLine(
                String(originalLine)
            )
        }

        return (
            String(value[..<range.lowerBound]),
            String(value[range.upperBound...])
        )
    }
}
