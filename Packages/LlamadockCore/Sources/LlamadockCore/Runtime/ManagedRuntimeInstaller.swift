import Foundation

public enum ManagedRuntimeInstallStage:
    String,
    Equatable,
    Sendable
{
    case fetchingRelease
    case downloading
    case verifyingArchive
    case extracting
    case validatingBinaries
    case registering
    case activating
}

public enum ManagedRuntimeInstallState:
    Equatable,
    Sendable
{
    case idle
    case fetchingRelease
    case downloading(tag: String)
    case verifyingArchive
    case extracting
    case validatingBinaries
    case registering
    case activating
    case ready(ManagedRuntimeRecord)
    case failed(
        stage: ManagedRuntimeInstallStage,
        reason: String
    )
}

public struct ManagedRuntimeInstallSnapshot:
    Equatable,
    Sendable
{
    public let state: ManagedRuntimeInstallState
    public let transitions: [ManagedRuntimeInstallState]

    public init(
        state: ManagedRuntimeInstallState = .idle,
        transitions: [ManagedRuntimeInstallState] = [.idle]
    ) {
        self.state = state
        self.transitions = transitions
    }
}

public enum ManagedRuntimeInstallError:
    Error,
    Equatable,
    Sendable
{
    case installationAlreadyInProgress
    case finalDirectoryAlreadyExists(URL)
    case unexpectedDownloadDestination(
        expected: URL,
        actual: URL
    )
}

extension ManagedRuntimeInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .installationAlreadyInProgress:
            "A managed runtime installation is already in progress."
        case .finalDirectoryAlreadyExists(let url):
            "The managed runtime directory already exists: \(url.path)"
        case .unexpectedDownloadDestination(let expected, let actual):
            """
            The runtime downloader returned an unexpected file. \
            Expected \(expected.path), got \(actual.path).
            """
        }
    }
}

public actor ManagedRuntimeInstaller {
    private let directories: ApplicationDirectories
    private let releaseChecker: any RuntimeReleaseChecking
    private let downloader: any RuntimeArchiveDownloading
    private let verifier: any RuntimeArchiveVerifying
    private let extractor: any RuntimeArchiveExtracting
    private let runtimeValidator: any PreparedManagedRuntimeValidating
    private let registry: any ManagedRuntimeRegistering
    private let fileManager: FileManager

    private var currentSnapshot = ManagedRuntimeInstallSnapshot()
    private var isInstalling = false

    public init(
        directories: ApplicationDirectories,
        releaseChecker: any RuntimeReleaseChecking,
        downloader: any RuntimeArchiveDownloading =
            URLSessionRuntimeArchiveDownloader(),
        verifier: any RuntimeArchiveVerifying =
            RuntimeArchiveVerifier(),
        extractor: any RuntimeArchiveExtracting =
            BSDTarRuntimeArchiveExtractor(),
        runtimeValidator: any PreparedManagedRuntimeValidating =
            PreparedManagedRuntimeValidator(),
        registry: any ManagedRuntimeRegistering,
        fileManager: FileManager = .default
    ) {
        self.directories = directories
        self.releaseChecker = releaseChecker
        self.downloader = downloader
        self.verifier = verifier
        self.extractor = extractor
        self.runtimeValidator = runtimeValidator
        self.registry = registry
        self.fileManager = fileManager
    }

    public func snapshot() -> ManagedRuntimeInstallSnapshot {
        currentSnapshot
    }

    @discardableResult
    public func installLatest(
        activateAfterInstall: Bool,
        now: Date = Date()
    ) async throws -> ManagedRuntimeRecord {
        guard !isInstalling else {
            throw ManagedRuntimeInstallError
                .installationAlreadyInProgress
        }
        isInstalling = true
        currentSnapshot = ManagedRuntimeInstallSnapshot()
        defer {
            isInstalling = false
        }

        var stage = ManagedRuntimeInstallStage.fetchingRelease
        var transactionURL: URL?
        var movedFinalURL: URL?
        var registered = false

        do {
            try fileManager.createDirectory(
                at: directories.runtimeDownloads,
                withIntermediateDirectories: true
            )
            transition(to: .fetchingRelease)
            let check = try await releaseChecker.checkLatest(
                now: now
            )
            let release = check.release
            let finalDirectory = directories.runtimes.appending(
                path: "\(release.tag)-macos-arm64",
                directoryHint: .isDirectory
            )

            stage = .downloading
            transition(to: .downloading(tag: release.tag))
            let transaction = directories.runtimeDownloads.appending(
                path: "install-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            transactionURL = transaction
            let archiveURL = transaction.appending(
                path: "asset.part",
                directoryHint: .notDirectory
            )
            let downloadedURL = try await downloader.download(
                asset: release.asset,
                destinationURL: archiveURL
            )
            guard
                downloadedURL.standardizedFileURL
                    == archiveURL.standardizedFileURL
            else {
                throw ManagedRuntimeInstallError
                    .unexpectedDownloadDestination(
                        expected: archiveURL,
                        actual: downloadedURL
                    )
            }

            stage = .verifyingArchive
            transition(to: .verifyingArchive)
            let verification = try verifier.verify(
                archiveURL: archiveURL,
                asset: release.asset
            )

            stage = .extracting
            transition(to: .extracting)
            let extractedRoot = transaction.appending(
                path: "extracted",
                directoryHint: .isDirectory
            )
            try await extractor.extract(
                archiveURL: archiveURL,
                destinationURL: extractedRoot
            )

            stage = .validatingBinaries
            transition(to: .validatingBinaries)
            let record = try await runtimeValidator.validate(
                extractedRoot: extractedRoot,
                intendedInstallDirectory: finalDirectory,
                release: release,
                archiveSHA256: verification.sha256,
                now: now
            )

            guard !fileManager.fileExists(
                atPath: finalDirectory.path
            ) else {
                throw ManagedRuntimeInstallError
                    .finalDirectoryAlreadyExists(finalDirectory)
            }
            try fileManager.moveItem(
                at: extractedRoot,
                to: finalDirectory
            )
            movedFinalURL = finalDirectory

            stage = .registering
            transition(to: .registering)
            try await registry.register(record)
            registered = true

            if activateAfterInstall {
                stage = .activating
                transition(to: .activating)
                try await registry.activate(record.id)
            }

            transition(to: .ready(record))
            cleanup(transactionURL)
            return record
        } catch {
            if !registered, let movedFinalURL {
                try? fileManager.removeItem(at: movedFinalURL)
            }
            cleanup(transactionURL)
            transition(
                to: .failed(
                    stage: stage,
                    reason: diagnosticDescription(error)
                )
            )
            throw error
        }
    }

    private func transition(
        to state: ManagedRuntimeInstallState
    ) {
        var transitions = currentSnapshot.transitions
        transitions.append(state)
        currentSnapshot = ManagedRuntimeInstallSnapshot(
            state: state,
            transitions: transitions
        )
    }

    private func cleanup(
        _ transactionURL: URL?
    ) {
        guard let transactionURL else {
            return
        }
        try? fileManager.removeItem(at: transactionURL)
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
