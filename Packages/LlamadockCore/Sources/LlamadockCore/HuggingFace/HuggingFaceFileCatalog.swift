import Foundation

public struct HuggingFaceFileCatalogBuilder: Sendable {
    public init() {}

    public func makeCatalog(
        files: [HuggingFaceRepositoryFile]
    ) -> HuggingFaceRepositoryCatalog {
        var ignoredPaths: [String] = []
        var grouped: [String: [HuggingFaceGGUFFile]] = [:]
        var displayNames: [String: String] = [:]

        for file in files {
            guard
                isSafeRelativePath(file.path),
                file.pathExtension.caseInsensitiveCompare("gguf")
                    == .orderedSame
            else {
                ignoredPaths.append(file.path)
                continue
            }

            let filename = file.lastPathComponent
            let role = role(for: filename)
            let splitMatch = splitPart(in: filename)
            let groupName = splitMatch?.baseName ?? filename
            let quantization = quantization(in: groupName)
            let key = "\(role.rawValue):\(groupName.lowercased())"
            let ggufFile = HuggingFaceGGUFFile(
                repositoryFile: file,
                role: role,
                quantization: quantization,
                split: splitMatch?.part
            )
            grouped[key, default: []].append(ggufFile)
            displayNames[key] = groupName
        }

        let artifacts = grouped.map { key, groupFiles in
            let sortedFiles = groupFiles.sorted {
                let lhsIndex = $0.split?.index ?? 0
                let rhsIndex = $1.split?.index ?? 0
                if lhsIndex == rhsIndex {
                    return $0.repositoryFile.path
                        .localizedStandardCompare(
                            $1.repositoryFile.path
                        ) == .orderedAscending
                }
                return lhsIndex < rhsIndex
            }
            let role = sortedFiles[0].role
            return HuggingFaceGGUFArtifact(
                id: key,
                displayName: displayNames[key] ?? key,
                role: role,
                quantization: sortedFiles.compactMap(
                    \.quantization
                ).first,
                files: sortedFiles,
                totalSize: totalSize(of: sortedFiles),
                isComplete: isComplete(sortedFiles)
            )
        }.sorted(by: compareArtifacts)

        return HuggingFaceRepositoryCatalog(
            artifacts: artifacts,
            ignoredPaths: ignoredPaths.sorted()
        )
    }

    private func role(
        for filename: String
    ) -> HuggingFaceGGUFRole {
        let normalized = filename.lowercased()
        if
            normalized.hasPrefix("mmproj")
                || normalized.contains("-mmproj")
                || normalized.contains(".mmproj")
        {
            return .mmproj
        }
        if
            normalized.contains("draft")
                || normalized.contains("mtp")
        {
            return .draft
        }
        return .main
    }

    private func splitPart(
        in filename: String
    ) -> (
        baseName: String,
        part: HuggingFaceSplitPart
    )? {
        let pattern = #"(?i)([-.])([0-9]{5})-of-([0-9]{5})(?=\.gguf$)"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern
            ),
            let match = expression.firstMatch(
                in: filename,
                range: NSRange(filename.startIndex..., in: filename)
            ),
            let fullRange = Range(match.range(at: 0), in: filename),
            let indexRange = Range(match.range(at: 2), in: filename),
            let countRange = Range(match.range(at: 3), in: filename),
            let index = Int(filename[indexRange]),
            let count = Int(filename[countRange]),
            count > 0
        else {
            return nil
        }

        var baseName = filename
        baseName.removeSubrange(fullRange)
        return (
            baseName,
            HuggingFaceSplitPart(index: index, count: count)
        )
    }

    private func quantization(
        in filename: String
    ) -> String? {
        let pattern = #"(?i)(?<![A-Za-z0-9])((?:UD-)?(?:IQ|Q)[0-9]+(?:_[A-Za-z0-9]+)+|(?:BF|F)[0-9]{2})(?![A-Za-z0-9])"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern
            ),
            let match = expression.firstMatch(
                in: filename,
                range: NSRange(filename.startIndex..., in: filename)
            ),
            let range = Range(match.range(at: 1), in: filename)
        else {
            return nil
        }
        return String(filename[range])
    }

    private func isComplete(
        _ files: [HuggingFaceGGUFFile]
    ) -> Bool {
        let splitParts = files.compactMap(\.split)
        guard !splitParts.isEmpty else {
            return files.count == 1
        }
        guard splitParts.count == files.count else {
            return false
        }
        let counts = Set(splitParts.map(\.count))
        guard counts.count == 1, let expectedCount = counts.first else {
            return false
        }
        return splitParts.count == expectedCount
            && Set(splitParts.map(\.index))
                == Set(1...expectedCount)
    }

    private func totalSize(
        of files: [HuggingFaceGGUFFile]
    ) -> Int64 {
        files.reduce(0) { partial, file in
            let value = max(file.repositoryFile.size, 0)
            let sum = partial.addingReportingOverflow(value)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    private func compareArtifacts(
        _ lhs: HuggingFaceGGUFArtifact,
        _ rhs: HuggingFaceGGUFArtifact
    ) -> Bool {
        let order: [HuggingFaceGGUFRole: Int] = [
            .main: 0,
            .mmproj: 1,
            .draft: 2,
        ]
        let lhsOrder = order[lhs.role] ?? Int.max
        let rhsOrder = order[rhs.role] ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        return lhs.displayName.localizedStandardCompare(
            rhs.displayName
        ) == .orderedAscending
    }
}

private extension HuggingFaceRepositoryFile {
    var pathExtension: String {
        URL(
            filePath: path,
            directoryHint: .notDirectory
        ).pathExtension
    }

    var lastPathComponent: String {
        URL(
            filePath: path,
            directoryHint: .notDirectory
        ).lastPathComponent
    }
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
