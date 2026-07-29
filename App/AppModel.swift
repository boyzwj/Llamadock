import Foundation
import LlamadockCore
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedSection: AppSection? = .overview
    var runtimeReports: [RuntimeProbeReport] = []
    var runtimes: [RuntimeInstallation] = []
    var selectedRuntimeID: String?
    var managedRuntimeSnapshot = ManagedRuntimeRegistrySnapshot(
        installations: [],
        activeRuntimeID: nil,
        previousRuntimeID: nil
    )
    var latestRuntimeRelease: RuntimeReleaseCheck?
    var runtimeUpdateError: String?
    var runtimeInstallSnapshot = ManagedRuntimeInstallSnapshot()
    var selectedModelURL: URL?
    var profile: LaunchProfile?
    var commandPreview: String?
    var commandError: String?
    var serverSnapshot = ServerSnapshot(
        state: .stopped,
        run: nil,
        logs: []
    )
    var isBootstrapping = false
    var isRefreshingRuntimes = false
    var isCheckingRuntimeUpdates = false
    var isInstallingRuntime = false
    var isServerOperationInProgress = false
    var visibleError: String?

    private let runtimeDiscovery: RuntimeCandidateDiscovery
    private let runtimeProbe: RuntimeProbe
    private let managedRuntimeRegistry: any ManagedRuntimeRegistering
    private let runtimeReleaseCache: any RuntimeReleaseCaching
    private let runtimeReleaseChecker: any RuntimeReleaseChecking
    private let managedRuntimeInstaller: ManagedRuntimeInstaller
    private let profileStore: JSONProfileStore
    private let serverController: ServerProcessController
    private let userDefaults: UserDefaults
    private var didBootstrap = false
    private var serverMonitorTask: Task<Void, Never>?
    private var runtimeInstallMonitorTask: Task<Void, Never>?

    init(
        runtimeDiscovery: RuntimeCandidateDiscovery = RuntimeCandidateDiscovery(),
        runtimeProbe: RuntimeProbe = RuntimeProbe(timeoutSeconds: 30),
        serverController: ServerProcessController = ServerProcessController(),
        userDefaults: UserDefaults = .standard,
        applicationDirectories: ApplicationDirectories? = nil,
        managedRuntimeRegistry: (
            any ManagedRuntimeRegistering
        )? = nil,
        runtimeReleaseChecker: (
            any RuntimeReleaseChecking
        )? = nil,
        runtimeReleaseCache: (
            any RuntimeReleaseCaching
        )? = nil,
        managedRuntimeInstaller: ManagedRuntimeInstaller? = nil
    ) {
        self.runtimeDiscovery = runtimeDiscovery
        self.runtimeProbe = runtimeProbe
        self.serverController = serverController
        self.userDefaults = userDefaults

        let directories: ApplicationDirectories
        if let applicationDirectories {
            directories = applicationDirectories
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            directories = ApplicationDirectories(
                root: applicationSupport.appending(
                    path: "Llamadock",
                    directoryHint: .isDirectory
                )
            )
        }

        let registry: any ManagedRuntimeRegistering
        if let managedRuntimeRegistry {
            registry = managedRuntimeRegistry
        } else {
            registry = JSONManagedRuntimeRegistry(
                fileURL: directories.runtimeRegistry,
                runtimesRoot: directories.runtimes
            )
        }
        self.managedRuntimeRegistry = registry

        let releaseCache: any RuntimeReleaseCaching
        if let runtimeReleaseCache {
            releaseCache = runtimeReleaseCache
        } else {
            releaseCache = JSONRuntimeReleaseCache(
                fileURL: directories.latestRuntimeReleaseCache
            )
        }
        self.runtimeReleaseCache = releaseCache

        let releaseChecker: any RuntimeReleaseChecking
        if let runtimeReleaseChecker {
            releaseChecker = runtimeReleaseChecker
        } else {
            releaseChecker = GitHubLatestRuntimeReleaseClient(
                cache: releaseCache
            )
        }
        self.runtimeReleaseChecker = releaseChecker
        self.managedRuntimeInstaller = managedRuntimeInstaller
            ?? ManagedRuntimeInstaller(
                directories: directories,
                releaseChecker: releaseChecker,
                registry: registry
            )

        profileStore = JSONProfileStore(
            directory: directories.profiles
        )
    }

    func bootstrap() async {
        guard !didBootstrap else {
            return
        }
        didBootstrap = true
        isBootstrapping = true
        defer { isBootstrapping = false }

        await refreshRuntimes()

        do {
            let profiles = try await profileStore.loadAll()
            if let restoredProfile = profiles.first {
                profile = restoredProfile
                selectedModelURL = URL(
                    filePath: restoredProfile.model.mainPath,
                    directoryHint: .notDirectory
                )
                if
                    let runtimeID = restoredProfile.runtimeSelection.runtimeID,
                    runtimes.contains(where: { $0.id == runtimeID })
                {
                    selectedRuntimeID = runtimeID
                }
            }
        } catch {
            visibleError = "Could not restore profiles: \(error.localizedDescription)"
        }

        if selectedRuntimeID == nil {
            selectedRuntimeID = preferredRuntimeID(
                in: runtimes
            )
        }
        refreshCommandPreview()

        Task { [weak self] in
            await self?.checkRuntimeUpdatesIfDue()
        }
    }

    func refreshRuntimes() async {
        isRefreshingRuntimes = true
        defer { isRefreshingRuntimes = false }

        let registrySnapshot: ManagedRuntimeRegistrySnapshot
        do {
            registrySnapshot = try await managedRuntimeRegistry
                .snapshot()
            managedRuntimeSnapshot = registrySnapshot
        } catch {
            registrySnapshot = ManagedRuntimeRegistrySnapshot(
                installations: [],
                activeRuntimeID: nil,
                previousRuntimeID: nil
            )
            managedRuntimeSnapshot = registrySnapshot
            visibleError = """
                Could not read the managed runtime registry: \
                \(error.localizedDescription)
                """
        }

        let candidates = runtimeDiscovery.discover(
            managedRuntimes: registrySnapshot.installations,
            customExecutableURLs: persistedCustomRuntimeURLs()
        )
        var reports: [RuntimeProbeReport] = []
        var validRuntimes: [RuntimeInstallation] = []

        for candidate in candidates {
            let report = await runtimeProbe.probe(candidate)
            reports.append(report)

            guard
                report.validation == .valid,
                let serverURL = candidate.serverURL,
                let versionOutput = report.serverVersionOutput,
                let capabilities = report.capabilities
            else {
                continue
            }

            validRuntimes.append(
                RuntimeInstallation(
                    id: candidate.id,
                    source: candidate.source,
                    llamaURL: candidate.llamaURL,
                    serverURL: serverURL,
                    versionOutput: versionOutput,
                    capabilities: capabilities
                )
            )
        }

        runtimeReports = reports
        runtimes = validRuntimes
        if
            selectedRuntimeID == nil
                || !validRuntimes.contains(
                    where: { $0.id == selectedRuntimeID }
                )
        {
            selectedRuntimeID = preferredRuntimeID(
                in: validRuntimes
            )
        }
        refreshCommandPreview()
    }

    func checkRuntimeUpdates(
        reportErrors: Bool = true
    ) async {
        guard !isCheckingRuntimeUpdates else {
            return
        }
        isCheckingRuntimeUpdates = true
        runtimeUpdateError = nil
        defer { isCheckingRuntimeUpdates = false }

        do {
            let check = try await runtimeReleaseChecker.checkLatest(
                now: Date()
            )
            latestRuntimeRelease = check
            userDefaults.set(
                Date(),
                forKey: "lastManagedRuntimeUpdateCheck"
            )
        } catch {
            let message = """
                Could not check the latest llama.cpp runtime: \
                \(error.localizedDescription)
                """
            runtimeUpdateError = message
            if reportErrors {
                visibleError = message
            }
        }
    }

    func installLatestRuntime() async {
        guard canChangeManagedRuntime else {
            visibleError = """
                Stop the LlamaDock server before installing and activating \
                a managed runtime.
                """
            return
        }
        guard !isInstallingRuntime else {
            return
        }

        isInstallingRuntime = true
        beginRuntimeInstallMonitoring()
        defer {
            isInstallingRuntime = false
            runtimeInstallMonitorTask?.cancel()
            runtimeInstallMonitorTask = nil
        }

        do {
            let record = try await managedRuntimeInstaller
                .installLatest(activateAfterInstall: true)
            runtimeInstallSnapshot = await managedRuntimeInstaller
                .snapshot()
            await refreshRuntimes()
            selectRuntime(record.id)
        } catch {
            runtimeInstallSnapshot = await managedRuntimeInstaller
                .snapshot()
            visibleError = """
                Managed runtime installation failed: \
                \(error.localizedDescription)
                """
        }
    }

    func activateSelectedManagedRuntime() async {
        guard canChangeManagedRuntime else {
            visibleError = """
                Stop the LlamaDock server before switching runtimes.
                """
            return
        }
        guard
            let id = selectedRuntimeID,
            managedRuntimeSnapshot.installations.contains(
                where: { $0.id == id }
            )
        else {
            visibleError = "Choose an installed managed runtime first."
            return
        }

        do {
            try await managedRuntimeRegistry.activate(id)
            await refreshRuntimes()
            selectRuntime(id)
        } catch {
            visibleError = """
                Could not activate the managed runtime: \
                \(error.localizedDescription)
                """
        }
    }

    func rollbackManagedRuntime() async {
        guard canChangeManagedRuntime else {
            visibleError = """
                Stop the LlamaDock server before rolling back runtimes.
                """
            return
        }

        do {
            try await managedRuntimeRegistry.rollback()
            let snapshot = try await managedRuntimeRegistry.snapshot()
            await refreshRuntimes()
            selectRuntime(snapshot.activeRuntimeID)
        } catch {
            visibleError = """
                Could not roll back the managed runtime: \
                \(error.localizedDescription)
                """
        }
    }

    func addCustomRuntime(_ executableURL: URL) async {
        let standardizedPath = executableURL.standardizedFileURL.path
        var paths = userDefaults.stringArray(
            forKey: "customRuntimeExecutablePaths"
        ) ?? []
        if !paths.contains(standardizedPath) {
            paths.append(standardizedPath)
            userDefaults.set(
                paths,
                forKey: "customRuntimeExecutablePaths"
            )
        }
        await refreshRuntimes()
        if let runtime = runtimes.first(
            where: {
                $0.serverURL.path == standardizedPath
                    || $0.llamaURL?.path == standardizedPath
            }
        ) {
            selectRuntime(runtime.id)
        }
    }

    func selectRuntime(_ id: String?) {
        let validatedID = id.flatMap { requestedID in
            runtimes.contains(where: { $0.id == requestedID })
                ? requestedID
                : nil
        }
        selectedRuntimeID = validatedID
        if var profile {
            profile.runtimeSelection = RuntimeSelection(
                policy: validatedID == nil ? .activeManaged : .specific,
                runtimeID: validatedID
            )
            profile.updatedAt = Date()
            self.profile = profile
            persist(profile)
        }
        refreshCommandPreview()
    }

    func selectModel(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == "gguf" else {
            visibleError = "Choose a .gguf model file."
            return
        }

        selectedModelURL = standardizedURL
        let now = Date()
        let modelName = standardizedURL.deletingPathExtension().lastPathComponent
        let newProfile = LaunchProfile(
            name: "\(modelName) Default",
            model: ModelPaths(mainPath: standardizedURL.path),
            runtimeSelection: RuntimeSelection(
                policy: selectedRuntimeID == nil
                    ? .activeManaged
                    : .specific,
                runtimeID: selectedRuntimeID
            ),
            server: ServerOptions(),
            createdAt: now,
            updatedAt: now
        )
        profile = newProfile
        persist(newProfile)
        refreshCommandPreview()
    }

    func updateProfile(
        _ mutation: (inout LaunchProfile) -> Void
    ) {
        guard var profile else {
            return
        }
        mutation(&profile)
        profile.updatedAt = Date()
        self.profile = profile
        persist(profile)
        refreshCommandPreview()
    }

    func startServer() async {
        guard let runtime = selectedRuntime else {
            visibleError = "Choose a validated llama.cpp runtime first."
            return
        }
        guard let profile else {
            visibleError = "Choose a GGUF model first."
            return
        }
        guard FileManager.default.fileExists(atPath: profile.model.mainPath) else {
            visibleError = "The selected GGUF model no longer exists."
            return
        }

        let invocation: ProcessInvocation
        do {
            invocation = try ServerInvocationBuilder().makeServerInvocation(
                profile: profile,
                runtime: runtime
            )
        } catch {
            visibleError = "Cannot build launch command: \(error)"
            return
        }

        isServerOperationInProgress = true
        beginServerMonitoring()
        defer { isServerOperationInProgress = false }

        do {
            try await serverController.start(
                profileID: profile.id,
                runtimeID: runtime.id,
                invocation: invocation,
                host: profile.server.host,
                port: profile.server.port
            )
        } catch {
            visibleError = "Could not start llama-server: \(error.localizedDescription)"
        }
        serverSnapshot = await serverController.snapshot()
    }

    func stopServer() async {
        isServerOperationInProgress = true
        defer { isServerOperationInProgress = false }

        await serverController.stop()
        serverSnapshot = await serverController.snapshot()
        serverMonitorTask?.cancel()
        serverMonitorTask = nil
    }

    func restartServer() async {
        await stopServer()
        await startServer()
    }

    func shutdown() async {
        await serverController.stop()
        serverMonitorTask?.cancel()
        serverMonitorTask = nil
        runtimeInstallMonitorTask?.cancel()
        runtimeInstallMonitorTask = nil
    }

    var selectedRuntime: RuntimeInstallation? {
        runtimes.first { $0.id == selectedRuntimeID }
    }

    var canChangeManagedRuntime: Bool {
        switch serverSnapshot.state {
        case .stopped, .failed:
            true
        case .starting, .ready, .degraded, .stopping:
            false
        }
    }

    var selectedManagedRuntimeID: String? {
        guard
            let selectedRuntimeID,
            managedRuntimeSnapshot.installations.contains(
                where: { $0.id == selectedRuntimeID }
            )
        else {
            return nil
        }
        return selectedRuntimeID
    }

    var isLatestManagedRuntimeInstalled: Bool {
        if let release = latestRuntimeRelease?.release {
            return managedRuntimeSnapshot.installations.contains(
                where: {
                    $0.tag == release.tag
                        && $0.build == release.build
                }
            )
        }
        if case .ready(let record) = runtimeInstallSnapshot.state {
            return managedRuntimeSnapshot.installations.contains(
                where: { $0.id == record.id }
            )
        }
        return false
    }

    private func refreshCommandPreview() {
        guard let profile, let runtime = selectedRuntime else {
            commandPreview = nil
            commandError = nil
            return
        }

        do {
            let invocation = try ServerInvocationBuilder().makeServerInvocation(
                profile: profile,
                runtime: runtime
            )
            commandPreview = invocation.displayCommand
            commandError = nil
        } catch {
            commandPreview = nil
            commandError = String(describing: error)
        }
    }

    private func persist(_ profile: LaunchProfile) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.profileStore.save(profile)
            } catch {
                self.visibleError = "Could not save profile: \(error.localizedDescription)"
            }
        }
    }

    private func persistedCustomRuntimeURLs() -> [URL] {
        (
            userDefaults.stringArray(
                forKey: "customRuntimeExecutablePaths"
            ) ?? []
        ).map {
            URL(filePath: $0, directoryHint: .notDirectory)
        }
    }

    private func preferredRuntimeID(
        in installations: [RuntimeInstallation]
    ) -> String? {
        if
            let activeID = managedRuntimeSnapshot.activeRuntimeID,
            installations.contains(where: { $0.id == activeID })
        {
            return activeID
        }
        return installations.first?.id
    }

    private func checkRuntimeUpdatesIfDue() async {
        if
            let lastCheck = userDefaults.object(
                forKey: "lastManagedRuntimeUpdateCheck"
            ) as? Date,
            Date().timeIntervalSince(lastCheck) < 86_400
        {
            do {
                if let cached = try await runtimeReleaseCache.load() {
                    latestRuntimeRelease = RuntimeReleaseCheck(
                        release: cached.release,
                        source: .notModifiedCache,
                        fetchedAt: cached.fetchedAt,
                        warning: nil
                    )
                }
            } catch {
                runtimeUpdateError = """
                    Could not read the cached llama.cpp release: \
                    \(error.localizedDescription)
                    """
            }
            return
        }
        await checkRuntimeUpdates(reportErrors: false)
    }

    private func beginRuntimeInstallMonitoring() {
        runtimeInstallMonitorTask?.cancel()
        runtimeInstallMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let snapshot = await self.managedRuntimeInstaller
                    .snapshot()
                self.runtimeInstallSnapshot = snapshot

                switch snapshot.state {
                case .ready, .failed:
                    if !self.isInstallingRuntime {
                        return
                    }
                case .idle, .fetchingRelease, .downloading,
                    .verifyingArchive, .extracting,
                    .validatingBinaries, .registering,
                    .activating:
                    break
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func beginServerMonitoring() {
        serverMonitorTask?.cancel()
        serverMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let snapshot = await self.serverController.snapshot()
                self.serverSnapshot = snapshot

                switch snapshot.state {
                case .failed, .stopped:
                    if !self.isServerOperationInProgress {
                        return
                    }
                case .starting, .ready, .degraded, .stopping:
                    break
                }

                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
