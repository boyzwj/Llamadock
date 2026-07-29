import Foundation

public struct RuntimeCandidateDiscovery: Sendable {
    private let fileSystem: any FileSystemInspecting
    private let homebrewBinDirectories: [URL]

    public init(
        fileSystem: any FileSystemInspecting = LocalFileSystemInspector(),
        homebrewBinDirectories: [URL] = [
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
        ]
    ) {
        self.fileSystem = fileSystem
        self.homebrewBinDirectories = homebrewBinDirectories
    }

    public func discover(
        managedRuntimes: [ManagedRuntimeRecord] = [],
        customExecutableURLs: [URL] = []
    ) -> [RuntimeCandidate] {
        var candidates: [RuntimeCandidate] = []
        var claimedExecutablePaths = Set<String>()

        for runtime in managedRuntimes.sorted(
            by: { lhs, rhs in
                if lhs.build == rhs.build {
                    return lhs.id < rhs.id
                }
                return lhs.build > rhs.build
            }
        ) {
            let candidate = RuntimeCandidate(
                source: .managed,
                llamaURL: runtime.llamaURL,
                serverURL: runtime.serverURL,
                id: runtime.id
            )
            candidates.append(candidate)
            [candidate.llamaURL, candidate.serverURL]
                .compactMap(\.self)
                .forEach {
                    claimedExecutablePaths.insert($0.path)
                }
        }

        for directory in homebrewBinDirectories {
            let llamaURL = executableIfPresent(
                directory.appending(path: "llama", directoryHint: .notDirectory)
            )
            let serverURL = executableIfPresent(
                directory.appending(
                    path: "llama-server",
                    directoryHint: .notDirectory
                )
            )

            guard llamaURL != nil || serverURL != nil else {
                continue
            }

            candidates.append(
                RuntimeCandidate(
                    source: .homebrew,
                    llamaURL: llamaURL,
                    serverURL: serverURL
                )
            )
            [llamaURL, serverURL].compactMap(\.self).forEach {
                claimedExecutablePaths.insert($0.path)
            }
        }

        for selectedURL in customExecutableURLs {
            let executableURL = selectedURL.standardizedFileURL
            guard
                fileSystem.isExecutableFile(at: executableURL),
                !claimedExecutablePaths.contains(executableURL.path)
            else {
                continue
            }

            let candidate = customCandidate(for: executableURL)
            candidates.append(candidate)
            [candidate.llamaURL, candidate.serverURL]
                .compactMap(\.self)
                .forEach { claimedExecutablePaths.insert($0.path) }
        }

        return candidates
    }

    private func customCandidate(for selectedURL: URL) -> RuntimeCandidate {
        let directory = selectedURL.deletingLastPathComponent()

        if selectedURL.lastPathComponent == "llama" {
            return RuntimeCandidate(
                source: .custom,
                llamaURL: selectedURL,
                serverURL: executableIfPresent(
                    directory.appending(
                        path: "llama-server",
                        directoryHint: .notDirectory
                    )
                )
            )
        }

        return RuntimeCandidate(
            source: .custom,
            llamaURL: executableIfPresent(
                directory.appending(path: "llama", directoryHint: .notDirectory)
            ),
            serverURL: selectedURL
        )
    }

    private func executableIfPresent(_ url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        return fileSystem.isExecutableFile(at: standardizedURL)
            ? standardizedURL
            : nil
    }
}
