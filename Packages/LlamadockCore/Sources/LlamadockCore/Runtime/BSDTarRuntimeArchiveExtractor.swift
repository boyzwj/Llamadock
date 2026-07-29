import Foundation

public protocol RuntimeArchiveExtracting: Sendable {
    func extract(
        archiveURL: URL,
        destinationURL: URL
    ) async throws
}

public struct BSDTarRuntimeArchiveExtractor:
    RuntimeArchiveExtracting,
    @unchecked Sendable
{
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let tarURL: URL
    private let parser: BSDTarVerboseListingParser
    private let validator: RuntimeArchiveManifestValidator
    private let inspectionTimeout: Duration
    private let extractionTimeout: Duration

    public init(
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        tarURL: URL = URL(filePath: "/usr/bin/tar"),
        parser: BSDTarVerboseListingParser = BSDTarVerboseListingParser(),
        validator: RuntimeArchiveManifestValidator = RuntimeArchiveManifestValidator(),
        inspectionTimeout: Duration = .seconds(30),
        extractionTimeout: Duration = .seconds(120)
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.tarURL = tarURL
        self.parser = parser
        self.validator = validator
        self.inspectionTimeout = inspectionTimeout
        self.extractionTimeout = extractionTimeout
    }

    public func extract(
        archiveURL: URL,
        destinationURL: URL
    ) async throws {
        let listing = try await processRunner.run(
            try ProcessInvocation(
                executableURL: tarURL,
                arguments: ["-tvf", archiveURL.path],
                environment: ["LC_ALL": "C"]
            ),
            timeout: inspectionTimeout
        )
        try requireSuccess(
            listing,
            stage: "inspection"
        )
        try validator.validate(
            parser.parse(listing.standardOutput)
        )

        guard !fileManager.fileExists(
            atPath: destinationURL.path
        ) else {
            throw RuntimeArchiveError.destinationAlreadyExists(
                destinationURL
            )
        }
        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        do {
            let extraction = try await processRunner.run(
                try ProcessInvocation(
                    executableURL: tarURL,
                    arguments: [
                        "--no-same-owner",
                        "--no-same-permissions",
                        "-xf",
                        archiveURL.path,
                        "-C",
                        destinationURL.path,
                    ],
                    environment: ["LC_ALL": "C"]
                ),
                timeout: extractionTimeout
            )
            try requireSuccess(
                extraction,
                stage: "extraction"
            )
            try validateExtractedLinks(
                in: destinationURL
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func requireSuccess(
        _ result: ProcessResult,
        stage: String
    ) throws {
        guard !result.timedOut else {
            throw RuntimeArchiveError.toolFailed(
                stage: stage,
                reason: "timed out"
            )
        }
        guard result.terminationStatus == 0 else {
            let reason = [
                result.standardError,
                result.standardOutput,
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
                ?? "exit code \(result.terminationStatus)"
            throw RuntimeArchiveError.toolFailed(
                stage: stage,
                reason: reason
            )
        }
    }

    private func validateExtractedLinks(
        in root: URL
    ) throws {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw RuntimeArchiveError.toolFailed(
                stage: "post-extraction validation",
                reason: "could not enumerate the extracted directory"
            )
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            guard values.isSymbolicLink == true else {
                continue
            }

            let resolvedPath = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            guard
                resolvedPath == rootPath
                    || resolvedPath.hasPrefix(rootPath + "/")
            else {
                throw RuntimeArchiveError.extractedLinkEscapes(
                    path: url.path
                )
            }
        }
    }
}
