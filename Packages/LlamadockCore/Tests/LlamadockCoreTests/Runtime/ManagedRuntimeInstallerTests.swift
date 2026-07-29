import Foundation
import Testing
@testable import LlamadockCore

@Suite("Managed runtime installer transaction")
struct ManagedRuntimeInstallerTests {
    @Test("installs registers and activates a validated release")
    func installsSuccessfully() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let release = makeRelease()
        let oldRecord = makeRecord(
            build: 10_175,
            runtimesRoot: directories.runtimes
        )
        let registry = InstallerRegistry(
            snapshot: ManagedRuntimeRegistrySnapshot(
                installations: [oldRecord],
                activeRuntimeID: oldRecord.id,
                previousRuntimeID: nil
            )
        )
        let installer = ManagedRuntimeInstaller(
            directories: directories,
            releaseChecker: StaticReleaseChecker(
                release: release
            ),
            downloader: FixtureArchiveDownloader(),
            verifier: StaticArchiveVerifier(),
            extractor: FixtureArchiveExtractor(),
            runtimeValidator: FixturePreparedRuntimeValidator(),
            registry: registry
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let record = try await installer.installLatest(
            activateAfterInstall: true,
            now: now
        )

        #expect(record.id == "managed:b10176:macos-arm64")
        #expect(
            FileManager.default.fileExists(
                atPath: record.serverURL.path
            )
        )
        let registrySnapshot = await registry.snapshot()
        #expect(registrySnapshot.activeRuntimeID == record.id)
        #expect(registrySnapshot.previousRuntimeID == oldRecord.id)
        #expect(
            registrySnapshot.installations.contains(record)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directories.runtimeDownloads.path
            )
            .isEmpty
        )

        let installerSnapshot = await installer.snapshot()
        #expect(installerSnapshot.state == .ready(record))
        #expect(
            installerSnapshot.transitions
                == [
                    .idle,
                    .fetchingRelease,
                    .downloading(tag: "b10176"),
                    .verifyingArchive,
                    .extracting,
                    .validatingBinaries,
                    .registering,
                    .activating,
                    .ready(record),
                ]
        )
    }

    @Test("verification failure leaves active and final directory unchanged")
    func verificationFailureIsNonDestructive() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let oldRecord = makeRecord(
            build: 10_175,
            runtimesRoot: directories.runtimes
        )
        let registry = InstallerRegistry(
            snapshot: ManagedRuntimeRegistrySnapshot(
                installations: [oldRecord],
                activeRuntimeID: oldRecord.id,
                previousRuntimeID: nil
            )
        )
        let installer = ManagedRuntimeInstaller(
            directories: directories,
            releaseChecker: StaticReleaseChecker(
                release: makeRelease()
            ),
            downloader: FixtureArchiveDownloader(),
            verifier: FailingArchiveVerifier(),
            extractor: FixtureArchiveExtractor(),
            runtimeValidator: FixturePreparedRuntimeValidator(),
            registry: registry
        )

        await #expect(throws: FakeInstallFailure.verification) {
            try await installer.installLatest(
                activateAfterInstall: true
            )
        }

        #expect(
            await registry.snapshot().activeRuntimeID
                == oldRecord.id
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: directories.runtimes
                    .appending(
                        path: "b10176-macos-arm64",
                        directoryHint: .isDirectory
                    )
                    .path
            )
        )
        let downloadEntries = (
            try? FileManager.default.contentsOfDirectory(
                atPath: directories.runtimeDownloads.path
            )
        ) ?? []
        #expect(downloadEntries.isEmpty)

        guard
            case .failed(let stage, let reason) =
                await installer.snapshot().state
        else {
            Issue.record("Expected failed installer state")
            return
        }
        #expect(stage == .verifyingArchive)
        #expect(reason.contains("verification"))
    }

    @Test("registry failure removes the unregistered final directory")
    func registryFailureCleansMovedDirectory() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let oldRecord = makeRecord(
            build: 10_175,
            runtimesRoot: directories.runtimes
        )
        let registry = InstallerRegistry(
            snapshot: ManagedRuntimeRegistrySnapshot(
                installations: [oldRecord],
                activeRuntimeID: oldRecord.id,
                previousRuntimeID: nil
            ),
            registerError: FakeInstallFailure.registry
        )
        let installer = ManagedRuntimeInstaller(
            directories: directories,
            releaseChecker: StaticReleaseChecker(
                release: makeRelease()
            ),
            downloader: FixtureArchiveDownloader(),
            verifier: StaticArchiveVerifier(),
            extractor: FixtureArchiveExtractor(),
            runtimeValidator: FixturePreparedRuntimeValidator(),
            registry: registry
        )

        await #expect(throws: FakeInstallFailure.registry) {
            try await installer.installLatest(
                activateAfterInstall: true
            )
        }

        let finalDirectory = directories.runtimes.appending(
            path: "b10176-macos-arm64",
            directoryHint: .isDirectory
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: finalDirectory.path
            )
        )
        #expect(
            await registry.snapshot().activeRuntimeID
                == oldRecord.id
        )
    }

    @Test("activation failure preserves the registered runtime for retry")
    func activationFailureKeepsRegisteredRuntime() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let oldRecord = makeRecord(
            build: 10_175,
            runtimesRoot: directories.runtimes
        )
        let registry = InstallerRegistry(
            snapshot: ManagedRuntimeRegistrySnapshot(
                installations: [oldRecord],
                activeRuntimeID: oldRecord.id,
                previousRuntimeID: nil
            ),
            activationError: FakeInstallFailure.activation
        )
        let installer = ManagedRuntimeInstaller(
            directories: directories,
            releaseChecker: StaticReleaseChecker(
                release: makeRelease()
            ),
            downloader: FixtureArchiveDownloader(),
            verifier: StaticArchiveVerifier(),
            extractor: FixtureArchiveExtractor(),
            runtimeValidator: FixturePreparedRuntimeValidator(),
            registry: registry
        )

        await #expect(throws: FakeInstallFailure.activation) {
            try await installer.installLatest(
                activateAfterInstall: true
            )
        }

        let snapshot = await registry.snapshot()
        #expect(snapshot.activeRuntimeID == oldRecord.id)
        #expect(
            snapshot.installations.contains(
                where: {
                    $0.id == "managed:b10176:macos-arm64"
                }
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: directories.runtimes.appending(
                    path: "b10176-macos-arm64/llama-b10176/llama-server"
                ).path
            )
        )
        guard
            case .failed(let stage, _) =
                await installer.snapshot().state
        else {
            Issue.record("Expected failed installer state")
            return
        }
        #expect(stage == .activating)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockInstallerTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    private func makeRelease() -> ManagedRuntimeRelease {
        ManagedRuntimeRelease(
            buildTag: LlamaBuildTag(
                tag: "b10176",
                build: 10_176
            ),
            publishedAt: Date(
                timeIntervalSince1970: 1_799_999_000
            ),
            asset: GitHubRuntimeReleaseAsset(
                id: 1,
                name: "llama-b10176-bin-macos-arm64.tar.gz",
                downloadURL: URL(
                    string: "https://github.com/ggml-org/llama.cpp/releases/download/b10176/runtime.tar.gz"
                )!,
                size: 4,
                contentType: "application/gzip",
                digest: nil
            )
        )
    }

    private func makeRecord(
        build: Int,
        runtimesRoot: URL
    ) -> ManagedRuntimeRecord {
        let tag = "b\(build)"
        let directory = runtimesRoot.appending(
            path: "\(tag)-macos-arm64",
            directoryHint: .isDirectory
        )
        return ManagedRuntimeRecord(
            id: "managed:\(tag):macos-arm64",
            tag: tag,
            build: build,
            architecture: .arm64,
            installDirectory: directory,
            llamaURL: directory.appending(
                path: "\(tag)/llama"
            ),
            serverURL: directory.appending(
                path: "\(tag)/llama-server"
            ),
            installedAt: .distantPast,
            validatedAt: .distantPast,
            versionOutput: "version: \(build)",
            archiveSHA256: String(repeating: "a", count: 64)
        )
    }
}

private enum FakeInstallFailure: Error {
    case verification
    case registry
    case activation
}

private struct StaticReleaseChecker: RuntimeReleaseChecking {
    let release: ManagedRuntimeRelease

    func checkLatest(
        now: Date
    ) async throws -> RuntimeReleaseCheck {
        RuntimeReleaseCheck(
            release: release,
            source: .network,
            fetchedAt: now,
            warning: nil
        )
    }
}

private actor FixtureArchiveDownloader:
    RuntimeArchiveDownloading
{
    func download(
        asset: GitHubRuntimeReleaseAsset,
        destinationURL: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: destinationURL)
        return destinationURL
    }
}

private struct StaticArchiveVerifier: RuntimeArchiveVerifying {
    func verify(
        archiveURL: URL,
        asset: GitHubRuntimeReleaseAsset
    ) throws -> RuntimeArchiveVerification {
        RuntimeArchiveVerification(
            byteCount: 4,
            sha256: String(repeating: "a", count: 64)
        )
    }
}

private struct FailingArchiveVerifier: RuntimeArchiveVerifying {
    func verify(
        archiveURL: URL,
        asset: GitHubRuntimeReleaseAsset
    ) throws -> RuntimeArchiveVerification {
        throw FakeInstallFailure.verification
    }
}

private actor FixtureArchiveExtractor:
    RuntimeArchiveExtracting
{
    func extract(
        archiveURL: URL,
        destinationURL: URL
    ) throws {
        let releaseRoot = destinationURL.appending(
            path: "llama-b10176",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: releaseRoot,
            withIntermediateDirectories: true
        )
        try Data("llama".utf8).write(
            to: releaseRoot.appending(path: "llama")
        )
        try Data("server".utf8).write(
            to: releaseRoot.appending(path: "llama-server")
        )
    }
}

private struct FixturePreparedRuntimeValidator:
    PreparedManagedRuntimeValidating
{
    func validate(
        extractedRoot: URL,
        intendedInstallDirectory: URL,
        release: ManagedRuntimeRelease,
        archiveSHA256: String,
        now: Date
    ) async throws -> ManagedRuntimeRecord {
        let releaseRoot = intendedInstallDirectory.appending(
            path: "llama-b10176",
            directoryHint: .isDirectory
        )
        return ManagedRuntimeRecord(
            id: "managed:b10176:macos-arm64",
            tag: "b10176",
            build: 10_176,
            architecture: .arm64,
            installDirectory: intendedInstallDirectory,
            llamaURL: releaseRoot.appending(path: "llama"),
            serverURL: releaseRoot.appending(
                path: "llama-server"
            ),
            installedAt: now,
            validatedAt: now,
            versionOutput: "version: 10176",
            archiveSHA256: archiveSHA256
        )
    }
}

private actor InstallerRegistry: ManagedRuntimeRegistering {
    private var currentSnapshot: ManagedRuntimeRegistrySnapshot
    private let registerError: Error?
    private let activationError: Error?

    init(
        snapshot: ManagedRuntimeRegistrySnapshot,
        registerError: Error? = nil,
        activationError: Error? = nil
    ) {
        self.currentSnapshot = snapshot
        self.registerError = registerError
        self.activationError = activationError
    }

    func snapshot() -> ManagedRuntimeRegistrySnapshot {
        currentSnapshot
    }

    func register(_ record: ManagedRuntimeRecord) throws {
        if let registerError {
            throw registerError
        }
        var installations = currentSnapshot.installations
        installations.removeAll { $0.id == record.id }
        installations.append(record)
        currentSnapshot = ManagedRuntimeRegistrySnapshot(
            installations: installations,
            activeRuntimeID: currentSnapshot.activeRuntimeID,
            previousRuntimeID: currentSnapshot.previousRuntimeID
        )
    }

    func activate(_ id: String) throws {
        if let activationError {
            throw activationError
        }
        guard currentSnapshot.installations.contains(
            where: { $0.id == id }
        ) else {
            throw ManagedRuntimeRegistryError.runtimeNotFound(id)
        }
        currentSnapshot = ManagedRuntimeRegistrySnapshot(
            installations: currentSnapshot.installations,
            activeRuntimeID: id,
            previousRuntimeID: currentSnapshot.activeRuntimeID
        )
    }

    func rollback() throws {
        guard let previous = currentSnapshot.previousRuntimeID else {
            throw ManagedRuntimeRegistryError.noPreviousRuntime
        }
        currentSnapshot = ManagedRuntimeRegistrySnapshot(
            installations: currentSnapshot.installations,
            activeRuntimeID: previous,
            previousRuntimeID: currentSnapshot.activeRuntimeID
        )
    }
}
