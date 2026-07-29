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
    var appUpdateCheck: AppUpdateCheck?
    var appUpdateError: String?
    var runtimeInstallSnapshot = ManagedRuntimeInstallSnapshot()
    var selectedModelURL: URL?
    var modelDirectories: [ResolvedModelDirectory] = []
    var modelDirectoryIssues: [ModelDirectoryResolutionIssue] = []
    var modelScanSnapshot: LocalModelScanSnapshot?
    var selectedLibraryModelID: String?
    var huggingFaceRepositories: [HuggingFaceRepository] = []
    var selectedHuggingFaceRepositoryID: String?
    var huggingFaceReference: HuggingFaceRepositoryReference?
    var huggingFaceCatalog: HuggingFaceRepositoryCatalog?
    var selectedHuggingFaceArtifactID: String?
    var selectedHuggingFaceCompanionArtifactIDs: Set<String> = []
    var isSearchingHuggingFace = false
    var isLoadingHuggingFaceRepository = false
    var huggingFaceError: String?
    var isHuggingFaceTokenConfigured = false
    var huggingFaceCredentialError: String?
    var modelDownloadSnapshot = ModelDownloadSnapshot()
    var modelDownloadError: String?
    var profiles: [LaunchProfile] = []
    var selectedProfileID: UUID?
    var profile: LaunchProfile? {
        get {
            guard let selectedProfileID else {
                return nil
            }
            return profiles.first {
                $0.id == selectedProfileID
            }
        }
        set {
            guard let newValue else {
                selectedProfileID = nil
                return
            }
            if let index = profiles.firstIndex(
                where: { $0.id == newValue.id }
            ) {
                profiles[index] = newValue
            } else {
                profiles.append(newValue)
            }
            selectedProfileID = newValue.id
        }
    }
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
    var isCheckingAppUpdates = false
    var isInstallingRuntime = false
    var isRefreshingModels = false
    var isServerOperationInProgress = false
    var visibleError: String?

    private let runtimeDiscovery: RuntimeCandidateDiscovery
    private let runtimeProbe: RuntimeProbe
    private let managedRuntimeRegistry: any ManagedRuntimeRegistering
    private let runtimeReleaseCache: any RuntimeReleaseCaching
    private let runtimeReleaseChecker: any RuntimeReleaseChecking
    private let appReleaseChecker: any AppReleaseChecking
    private let managedRuntimeInstaller: ManagedRuntimeInstaller
    private let profileStore: JSONProfileStore
    private let applicationDirectories: ApplicationDirectories
    private let modelDirectoryStore: JSONModelDirectoryStore
    private let modelScanner: LocalModelScanner
    private let huggingFaceClient: any HuggingFaceHubServing
    private let huggingFaceTokenStore: any HuggingFaceTokenStoring
    private let modelDownloadManager: ModelDownloadManager
    private let modelDownloadProfileFactory:
        ModelDownloadProfileFactory
    private let serverController: ServerProcessController
    private let userDefaults: UserDefaults
    private var didBootstrap = false
    private var serverMonitorTask: Task<Void, Never>?
    private var runtimeInstallMonitorTask: Task<Void, Never>?
    private var modelDownloadMonitorTask: Task<Void, Never>?
    private var serverModelSecurityScopes: [URL] = []
    private var observedCompletedDownloadIDs: Set<UUID> = []

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
        appReleaseChecker: (
            any AppReleaseChecking
        )? = nil,
        managedRuntimeInstaller: ManagedRuntimeInstaller? = nil,
        modelDirectoryStore: JSONModelDirectoryStore? = nil,
        modelScanner: LocalModelScanner = LocalModelScanner(),
        huggingFaceClient: (any HuggingFaceHubServing)? = nil,
        huggingFaceTokenStore: (
            any HuggingFaceTokenStoring
        )? = nil,
        modelDownloadManager: ModelDownloadManager? = nil,
        modelDownloadProfileFactory:
            ModelDownloadProfileFactory =
                ModelDownloadProfileFactory()
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
        self.applicationDirectories = directories
        self.modelDirectoryStore = modelDirectoryStore
            ?? JSONModelDirectoryStore(
                fileURL: directories.settings
            )
        self.modelScanner = modelScanner
        self.huggingFaceClient = huggingFaceClient
            ?? HuggingFaceHubClient()
        let tokenStore = huggingFaceTokenStore
            ?? KeychainHuggingFaceTokenStore()
        self.huggingFaceTokenStore = tokenStore
        self.modelDownloadManager = modelDownloadManager
            ?? ModelDownloadManager(
                directories: directories,
                tokenStore: tokenStore
            )
        self.modelDownloadProfileFactory =
            modelDownloadProfileFactory

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
        self.appReleaseChecker = appReleaseChecker
            ?? GitHubAppReleaseChecker()
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

        refreshHuggingFaceTokenState()
        do {
            try await modelDownloadManager.restore()
            modelDownloadSnapshot = await modelDownloadManager
                .snapshot()
            observedCompletedDownloadIDs = Set(
                modelDownloadSnapshot.jobs.compactMap {
                    $0.state == .completed ? $0.id : nil
                }
            )
            beginModelDownloadMonitor()
        } catch {
            modelDownloadError = """
                Could not restore model downloads: \
                \(error.localizedDescription)
                """
        }
        await refreshRuntimes()

        do {
            profiles = try await profileStore.loadAll()
            let persistedID = userDefaults.string(
                forKey: "selectedProfileID"
            ).flatMap(UUID.init(uuidString:))
            selectedProfileID = persistedID.flatMap { requestedID in
                profiles.contains(where: { $0.id == requestedID })
                    ? requestedID
                    : nil
            } ?? profiles.first?.id
            persistSelectedProfileID()
            if let restoredProfile = profile {
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
            await reconcileCompletedDownloadProfiles(
                selectNewProfile: selectedProfileID == nil
            )
        } catch {
            visibleError = "Could not restore profiles: \(error.localizedDescription)"
        }

        await refreshModels()

        if selectedRuntimeID == nil {
            selectedRuntimeID = preferredRuntimeID(
                in: runtimes
            )
        }
        refreshCommandPreview()

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.checkRuntimeUpdatesIfDue()
            await self.checkAppUpdatesIfDue()
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

    func checkAppUpdates(
        reportErrors: Bool = true
    ) async {
        guard !isCheckingAppUpdates else {
            return
        }
        isCheckingAppUpdates = true
        appUpdateError = nil
        defer { isCheckingAppUpdates = false }

        do {
            appUpdateCheck = try await appReleaseChecker
                .checkLatest(
                    currentVersion: appVersion,
                    now: Date()
                )
            userDefaults.set(
                Date(),
                forKey: "lastAppUpdateCheck"
            )
        } catch {
            let message = """
                Could not check for a LlamaDock app update: \
                \(error.localizedDescription)
                """
            appUpdateError = message
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
        selectedLibraryModelID = modelScanSnapshot?.models.first(
            where: { $0.url == standardizedURL }
        )?.id
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
        persistSelectedProfileID()
        persist(newProfile)
        refreshCommandPreview()
    }

    func refreshModels() async {
        guard !isRefreshingModels else {
            return
        }
        isRefreshingModels = true
        defer { isRefreshingModels = false }

        do {
            try FileManager.default.createDirectory(
                at: applicationDirectories.models,
                withIntermediateDirectories: true
            )
            let directorySnapshot = try await modelDirectoryStore
                .snapshot()
            modelDirectories = directorySnapshot.directories
            modelDirectoryIssues = directorySnapshot.issues

            let externalURLs = directorySnapshot.directories.map(
                \.url
            )
            let activeScopes = externalURLs.compactMap { url in
                url.startAccessingSecurityScopedResource()
                    ? url
                    : nil
            }
            defer {
                for url in activeScopes {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let snapshot = try await modelScanner.scan(
                roots: [applicationDirectories.models]
                    + externalURLs
            )
            modelScanSnapshot = snapshot

            if
                let selectedLibraryModelID,
                snapshot.models.contains(
                    where: { $0.id == selectedLibraryModelID }
                )
            {
                return
            }
            if let selectedModelURL {
                selectedLibraryModelID = snapshot.models.first(
                    where: { $0.url == selectedModelURL }
                )?.id
            } else {
                selectedLibraryModelID = snapshot.models.first?.id
            }
        } catch {
            visibleError = """
                Could not refresh the local model library: \
                \(error.localizedDescription)
                """
        }
    }

    func addModelDirectory(
        _ url: URL
    ) async {
        do {
            _ = try await modelDirectoryStore.addDirectory(url)
            await refreshModels()
        } catch {
            visibleError = """
                Could not add the model directory: \
                \(error.localizedDescription)
                """
        }
    }

    func removeModelDirectory(
        id: UUID
    ) async {
        do {
            _ = try await modelDirectoryStore.removeDirectory(
                id: id
            )
            await refreshModels()
        } catch {
            visibleError = """
                Could not remove the model directory: \
                \(error.localizedDescription)
                """
        }
    }

    func selectLibraryModel(
        _ id: String?
    ) {
        selectedLibraryModelID = id
        guard
            let id,
            let model = modelScanSnapshot?.models.first(
                where: { $0.id == id }
            )
        else {
            return
        }
        let matchingProfiles = profiles(for: model)
        if
            let selectedProfileID,
            matchingProfiles.contains(
                where: { $0.id == selectedProfileID }
            )
        {
            return
        }
        if let mostRecent = matchingProfiles.first {
            selectProfile(mostRecent.id)
        }
    }

    func searchHuggingFace(
        _ input: String
    ) async {
        guard !isSearchingHuggingFace else {
            return
        }
        isSearchingHuggingFace = true
        huggingFaceError = nil
        defer { isSearchingHuggingFace = false }

        do {
            let query = input.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let reference: HuggingFaceRepositoryReference?
            if isHuggingFaceReference(query) {
                reference = try HuggingFaceReferenceParser().parse(
                    query
                )
            } else {
                reference = nil
            }

            let token = try huggingFaceTokenStore.token()
            let repositories = try await huggingFaceClient.searchModels(
                query: reference?.repositoryID ?? query,
                limit: 50,
                token: token
            )
            if let reference {
                let exactRepository = repositories.first {
                    $0.id.caseInsensitiveCompare(
                        reference.repositoryID
                    ) == .orderedSame
                } ?? HuggingFaceRepository(
                    id: reference.repositoryID,
                    downloads: 0,
                    likes: 0,
                    lastModified: nil,
                    gated: .none,
                    isPrivate: false,
                    pipelineTag: nil,
                    tags: []
                )
                huggingFaceRepositories = [
                    exactRepository,
                ] + repositories.filter {
                    $0.id.caseInsensitiveCompare(
                        reference.repositoryID
                    ) != .orderedSame
                }
                selectedHuggingFaceRepositoryID = exactRepository.id
                try await loadHuggingFaceCatalog(
                    reference: reference,
                    token: token
                )
            } else {
                huggingFaceRepositories = repositories
                selectedHuggingFaceRepositoryID = repositories.first?.id
                if let repository = repositories.first {
                    try await loadHuggingFaceCatalog(
                        reference: HuggingFaceRepositoryReference(
                            repositoryID: repository.id
                        ),
                        token: token
                    )
                } else {
                    huggingFaceReference = nil
                    huggingFaceCatalog = nil
                    selectedHuggingFaceArtifactID = nil
                }
            }
        } catch {
            huggingFaceError = error.localizedDescription
        }
    }

    func selectHuggingFaceRepository(
        _ id: String?
    ) async {
        guard
            !isLoadingHuggingFaceRepository,
            let id
        else {
            return
        }
        selectedHuggingFaceRepositoryID = id
        huggingFaceError = nil
        do {
            try await loadHuggingFaceCatalog(
                reference: HuggingFaceRepositoryReference(
                    repositoryID: id
                ),
                token: try huggingFaceTokenStore.token()
            )
        } catch {
            huggingFaceError = error.localizedDescription
        }
    }

    func selectHuggingFaceArtifact(
        _ id: String?
    ) {
        guard
            let id,
            huggingFaceCatalog?.artifacts.first(
                where: {
                    $0.id == id
                        && $0.role == .main
                }
            ) != nil
        else {
            selectedHuggingFaceArtifactID = nil
            return
        }
        selectedHuggingFaceArtifactID = id
    }

    func setHuggingFaceCompanionArtifact(
        _ id: String,
        selected: Bool
    ) {
        guard
            let artifact = huggingFaceCatalog?.artifacts.first(
                where: {
                    $0.id == id
                        && $0.role != .main
                        && $0.isComplete
                }
            )
        else {
            return
        }
        if selected {
            let sameRoleIDs = Set(
                huggingFaceCatalog?.artifacts.compactMap {
                    $0.role == artifact.role ? $0.id : nil
                } ?? []
            )
            selectedHuggingFaceCompanionArtifactIDs
                .subtract(sameRoleIDs)
            selectedHuggingFaceCompanionArtifactIDs.insert(id)
        } else {
            selectedHuggingFaceCompanionArtifactIDs.remove(id)
        }
    }

    func refreshHuggingFaceTokenState() {
        do {
            isHuggingFaceTokenConfigured = try huggingFaceTokenStore
                .token() != nil
            huggingFaceCredentialError = nil
        } catch {
            isHuggingFaceTokenConfigured = false
            huggingFaceCredentialError = error.localizedDescription
        }
    }

    @discardableResult
    func saveHuggingFaceToken(
        _ token: String
    ) -> Bool {
        do {
            try huggingFaceTokenStore.saveToken(token)
            isHuggingFaceTokenConfigured = true
            huggingFaceCredentialError = nil
            return true
        } catch {
            huggingFaceCredentialError = error.localizedDescription
            return false
        }
    }

    func deleteHuggingFaceToken() {
        do {
            try huggingFaceTokenStore.deleteToken()
            isHuggingFaceTokenConfigured = false
            huggingFaceCredentialError = nil
        } catch {
            huggingFaceCredentialError = error.localizedDescription
        }
    }

    func downloadSelectedHuggingFaceArtifact() async {
        guard
            let reference = huggingFaceReference,
            let artifact = selectedHuggingFaceArtifact,
            artifact.role == .main,
            artifact.isComplete
        else {
            modelDownloadError = """
                Choose a complete main GGUF artifact to download.
                """
            return
        }
        if
            let repository = selectedHuggingFaceRepository,
            (
                repository.gated.requiresAuthentication
                    || repository.isPrivate
            ),
            !isHuggingFaceTokenConfigured
        {
            modelDownloadError = """
                Add a Hugging Face token in Settings before downloading \
                this restricted repository.
                """
            return
        }
        modelDownloadError = nil
        do {
            let artifacts = selectedHuggingFaceDownloadArtifacts
            let request = ModelDownloadRequest(
                reference: reference,
                displayName: artifact.displayName,
                quantization: artifact.quantization,
                files: artifacts.flatMap { selectedArtifact in
                    selectedArtifact.files.map { file in
                        ModelDownloadRequestFile(
                            artifactID: selectedArtifact.id,
                            artifactDisplayName:
                                selectedArtifact.displayName,
                            role: selectedArtifact.role,
                            repositoryPath:
                                file.repositoryFile.path,
                            expectedSize:
                                file.repositoryFile.size,
                            expectedSHA256:
                                file.repositoryFile
                                    .expectedSHA256
                        )
                    }
                }
            )
            _ = try await modelDownloadManager.enqueue(
                request
            )
            modelDownloadSnapshot = await modelDownloadManager
                .snapshot()
            beginModelDownloadMonitor()
        } catch {
            modelDownloadError = error.localizedDescription
        }
    }

    func pauseModelDownload(
        id: UUID
    ) async {
        await performModelDownloadAction {
            try await modelDownloadManager.pause(id: id)
        }
    }

    func resumeModelDownload(
        id: UUID
    ) async {
        await performModelDownloadAction {
            try await modelDownloadManager.resume(id: id)
        }
    }

    func cancelModelDownload(
        id: UUID
    ) async {
        await performModelDownloadAction {
            try await modelDownloadManager.cancel(id: id)
        }
    }

    func createProfile(
        for model: LocalModelFile
    ) {
        guard model.validation == .valid else {
            visibleError = """
                This GGUF file is invalid and cannot be used to create \
                a launch profile.
                """
            return
        }
        guard model.role == .main else {
            visibleError = """
                Choose a main model. Companion and auxiliary GGUF files \
                are attached from a profile.
                """
            return
        }
        selectModel(model.url)
        let profileCount = profiles(for: model).count
        if profileCount > 1 {
            updateProfile {
                $0.name = "\(model.displayName) Profile \(profileCount)"
            }
        }
    }

    func selectProfile(
        _ id: UUID?
    ) {
        guard
            let id,
            let selected = profiles.first(
                where: { $0.id == id }
            )
        else {
            return
        }
        selectedProfileID = id
        selectedModelURL = URL(
            filePath: selected.model.mainPath,
            directoryHint: .notDirectory
        ).standardizedFileURL
        selectedLibraryModelID = modelScanSnapshot?.models.first {
            canonicalPath($0.url.path)
                == canonicalPath(selected.model.mainPath)
        }?.id
        if
            let runtimeID = selected.runtimeSelection.runtimeID,
            runtimes.contains(where: { $0.id == runtimeID })
        {
            selectedRuntimeID = runtimeID
        } else {
            selectedRuntimeID = preferredRuntimeID(in: runtimes)
        }
        persistSelectedProfileID()
        refreshCommandPreview()
    }

    func duplicateSelectedProfile() {
        guard var duplicate = profile else {
            return
        }
        let now = Date()
        duplicate.id = UUID()
        duplicate.name = "\(duplicate.name) Copy"
        duplicate.createdAt = now
        duplicate.updatedAt = now
        duplicate.lastUsedAt = nil
        profile = duplicate
        persistSelectedProfileID()
        persist(duplicate)
        refreshCommandPreview()
    }

    func deleteSelectedProfile() async {
        guard let selected = profile else {
            return
        }
        if
            let run = serverSnapshot.run,
            run.profileID == selected.id
        {
            visibleError = "Stop the server before deleting its profile."
            return
        }

        do {
            try await profileStore.delete(id: selected.id)
            profiles.removeAll { $0.id == selected.id }
            let replacement = profiles.first {
                canonicalPath($0.model.mainPath)
                    == canonicalPath(selected.model.mainPath)
            } ?? profiles.first
            selectedProfileID = replacement?.id
            if let replacement {
                selectProfile(replacement.id)
            } else {
                selectedModelURL = nil
                selectedLibraryModelID = nil
                persistSelectedProfileID()
                refreshCommandPreview()
            }
        } catch {
            visibleError = """
                Could not delete the profile: \
                \(error.localizedDescription)
                """
        }
    }

    func importProfile(
        from url: URL
    ) async {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imported = try await profileStore.importProfile(
                from: Data(contentsOf: url)
            )
            profiles.append(imported)
            selectProfile(imported.id)
        } catch {
            visibleError = """
                Could not import the profile: \
                \(error.localizedDescription)
                """
        }
    }

    func exportSelectedProfile(
        to url: URL
    ) async {
        guard let profile else {
            return
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await profileStore.save(profile)
            guard
                let data = try await profileStore.exportData(
                    id: profile.id
                )
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            visibleError = """
                Could not export the profile: \
                \(error.localizedDescription)
                """
        }
    }

    func profiles(
        for model: LocalModelFile
    ) -> [LaunchProfile] {
        let modelPath = canonicalPath(model.url.path)
        return profiles.filter {
            canonicalPath($0.model.mainPath) == modelPath
        }.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.updatedAt > $1.updatedAt
        }
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
        persistSelectedProfileID()
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
        beginServerModelSecurityScope(for: profile)
        guard FileManager.default.fileExists(atPath: profile.model.mainPath) else {
            endServerModelSecurityScope()
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
            endServerModelSecurityScope()
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
            var usedProfile = profile
            usedProfile.lastUsedAt = Date()
            usedProfile.updatedAt = usedProfile.lastUsedAt ?? Date()
            self.profile = usedProfile
            persist(usedProfile)
        } catch {
            endServerModelSecurityScope()
            visibleError = "Could not start llama-server: \(error.localizedDescription)"
        }
        serverSnapshot = await serverController.snapshot()
    }

    func stopServer() async {
        isServerOperationInProgress = true
        defer { isServerOperationInProgress = false }

        await serverController.stop()
        endServerModelSecurityScope()
        serverSnapshot = await serverController.snapshot()
        serverMonitorTask?.cancel()
        serverMonitorTask = nil
    }

    func restartServer() async {
        await stopServer()
        await startServer()
    }

    func shutdown() async {
        await modelDownloadManager.suspendForTermination()
        modelDownloadMonitorTask?.cancel()
        modelDownloadMonitorTask = nil
        await serverController.stop()
        endServerModelSecurityScope()
        serverMonitorTask?.cancel()
        serverMonitorTask = nil
        runtimeInstallMonitorTask?.cancel()
        runtimeInstallMonitorTask = nil
    }

    var selectedRuntime: RuntimeInstallation? {
        runtimes.first { $0.id == selectedRuntimeID }
    }

    var selectedLibraryModel: LocalModelFile? {
        guard let selectedLibraryModelID else {
            return nil
        }
        return modelScanSnapshot?.models.first {
            $0.id == selectedLibraryModelID
        }
    }

    var localModels: [LocalModelFile] {
        modelScanSnapshot?.models ?? []
    }

    var selectedHuggingFaceRepository: HuggingFaceRepository? {
        guard let selectedHuggingFaceRepositoryID else {
            return nil
        }
        return huggingFaceRepositories.first {
            $0.id == selectedHuggingFaceRepositoryID
        }
    }

    var selectedHuggingFaceArtifact: HuggingFaceGGUFArtifact? {
        guard let selectedHuggingFaceArtifactID else {
            return nil
        }
        return huggingFaceCatalog?.artifacts.first {
            $0.id == selectedHuggingFaceArtifactID
        }
    }

    var selectedHuggingFaceCompanionArtifacts:
        [HuggingFaceGGUFArtifact]
    {
        (huggingFaceCatalog?.artifacts ?? [])
            .filter {
                selectedHuggingFaceCompanionArtifactIDs
                    .contains($0.id)
            }
            .sorted {
                if $0.role == $1.role {
                    return $0.displayName
                        .localizedStandardCompare(
                            $1.displayName
                        ) == .orderedAscending
                }
                return $0.role == .mmproj
            }
    }

    var selectedHuggingFaceDownloadArtifacts:
        [HuggingFaceGGUFArtifact]
    {
        guard let selectedHuggingFaceArtifact else {
            return []
        }
        return [selectedHuggingFaceArtifact]
            + selectedHuggingFaceCompanionArtifacts
    }

    var selectedHuggingFaceArtifactDownloadJob: ModelDownloadJob? {
        guard
            let reference = huggingFaceReference,
            let artifact = selectedHuggingFaceArtifact
        else {
            return nil
        }
        let selectedArtifactIDs = Set(
            selectedHuggingFaceDownloadArtifacts.map(\.id)
        )
        return modelDownloadSnapshot.jobs.last {
            $0.repositoryID == reference.repositoryID
                && $0.revision == reference.revision
                && Set($0.files.map(\.artifactID))
                    == selectedArtifactIDs
                && selectedArtifactIDs.contains(artifact.id)
                && $0.state != .cancelled
        }
    }

    var localModelByteCount: UInt64 {
        localModels.reduce(0) { partial, model in
            let sum = partial.addingReportingOverflow(
                model.fileSize
            )
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }

    var ownedModelsDirectoryURL: URL {
        applicationDirectories.models
    }

    private func loadHuggingFaceCatalog(
        reference: HuggingFaceRepositoryReference,
        token: String?
    ) async throws {
        isLoadingHuggingFaceRepository = true
        huggingFaceReference = reference
        huggingFaceCatalog = nil
        selectedHuggingFaceArtifactID = nil
        selectedHuggingFaceCompanionArtifactIDs = []
        defer { isLoadingHuggingFaceRepository = false }

        let files = try await huggingFaceClient.repositoryFiles(
            reference: reference,
            token: token
        )
        let catalog = HuggingFaceFileCatalogBuilder().makeCatalog(
            files: files
        )
        huggingFaceCatalog = catalog
        let preferredQuantization = reference.quantization?
            .lowercased()
        selectedHuggingFaceArtifactID = catalog.artifacts.first {
            guard let preferredQuantization else {
                return $0.role == .main && $0.isComplete
            }
            return $0.role == .main
                && $0.isComplete
                && $0.quantization?.lowercased()
                    == preferredQuantization
        }?.id ?? catalog.artifacts.first {
            $0.role == .main && $0.isComplete
        }?.id ?? catalog.artifacts.first {
            $0.role == .main
        }?.id
    }

    private func isHuggingFaceReference(
        _ input: String
    ) -> Bool {
        input.contains("/")
            || input.localizedCaseInsensitiveContains(
                "huggingface.co"
            )
            || input.contains("-hf")
            || input.contains("--hf-repo")
    }

    private func performModelDownloadAction(
        _ action: () async throws -> Void
    ) async {
        modelDownloadError = nil
        do {
            try await action()
            modelDownloadSnapshot = await modelDownloadManager
                .snapshot()
            beginModelDownloadMonitor()
        } catch {
            modelDownloadError = error.localizedDescription
        }
    }

    private func beginModelDownloadMonitor() {
        guard modelDownloadMonitorTask == nil else {
            return
        }
        modelDownloadMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let snapshot = await self.modelDownloadManager
                    .snapshot()
                self.modelDownloadSnapshot = snapshot

                let completed = Set(
                    snapshot.jobs.compactMap {
                        $0.state == .completed ? $0.id : nil
                    }
                )
                let newlyCompleted = completed.subtracting(
                    self.observedCompletedDownloadIDs
                )
                self.observedCompletedDownloadIDs = completed
                if !newlyCompleted.isEmpty {
                    await self.refreshModels()
                    for job in snapshot.jobs
                    where newlyCompleted.contains(job.id) {
                        await self.ensureProfile(
                            for: job,
                            select: true
                        )
                    }
                }

                try? await Task.sleep(
                    nanoseconds: snapshot.activeJobID == nil
                        ? 1_000_000_000
                        : 250_000_000
                )
            }
        }
    }

    private func reconcileCompletedDownloadProfiles(
        selectNewProfile: Bool
    ) async {
        var shouldSelect = selectNewProfile
        for job in modelDownloadSnapshot.jobs
        where job.state == .completed {
            _ = await ensureProfile(
                for: job,
                select: shouldSelect
            )
            if shouldSelect {
                shouldSelect = false
            }
        }
    }

    @discardableResult
    private func ensureProfile(
        for job: ModelDownloadJob,
        select: Bool
    ) async -> Bool {
        do {
            let candidate = try modelDownloadProfileFactory
                .makeProfile(
                    for: job,
                    modelsRoot: applicationDirectories.models,
                    runtimeID: selectedRuntimeID
                )
            if
                let existing = profiles.first(
                    where: {
                        canonicalPath($0.model.mainPath)
                            == canonicalPath(
                                candidate.model.mainPath
                            )
                            && canonicalOptionalPath(
                                $0.model.mmprojPath
                            )
                                == canonicalOptionalPath(
                                    candidate.model.mmprojPath
                                )
                            && canonicalOptionalPath(
                                $0.model.draftPath
                            )
                                == canonicalOptionalPath(
                                    candidate.model.draftPath
                                )
                    }
                )
            {
                if select {
                    selectProfile(existing.id)
                }
                return false
            }

            try await profileStore.save(candidate)
            profiles.append(candidate)
            profiles.sort {
                if $0.updatedAt == $1.updatedAt {
                    return $0.id.uuidString
                        < $1.id.uuidString
                }
                return $0.updatedAt > $1.updatedAt
            }
            if select {
                selectProfile(candidate.id)
            }
            return true
        } catch {
            modelDownloadError = """
                Model import completed, but its launch profile could not \
                be created: \(error.localizedDescription)
                """
            return false
        }
    }

    private func canonicalOptionalPath(
        _ path: String?
    ) -> String? {
        path.map(canonicalPath)
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

    var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey:
                "CFBundleShortVersionString"
        ) as? String ?? "1.0.0"
    }

    var appBuild: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
    }

    func makeDiagnosticsReport(
        generatedAt: Date = Date()
    ) -> String {
        let processInfo = ProcessInfo.processInfo
        let physicalMemory = ByteCountFormatter.string(
            fromByteCount: Int64(
                min(
                    processInfo.physicalMemory,
                    UInt64(Int64.max)
                )
            ),
            countStyle: .memory
        )
        let downloadEntries = modelDownloadSnapshot.jobs
            .enumerated()
            .map { index, job in
                DiagnosticsEntry(
                    "Job \(index + 1)",
                    [
                        job.repositoryID,
                        job.displayName,
                        job.state.rawValue,
                        "\(job.receivedBytes)/\(job.expectedBytes) bytes",
                        "\(job.files.count) files",
                        job.error,
                    ]
                    .compactMap { $0 }
                    .joined(separator: " • ")
                )
            }
        let runtimeEntries = runtimes.map { runtime in
            DiagnosticsEntry(
                runtime.id,
                [
                    runtime.source.rawValue,
                    runtime.versionOutput.split(
                        separator: "\n"
                    ).first.map(String.init),
                ]
                .compactMap { $0 }
                .joined(separator: " • ")
            )
        }
        let sections = [
            DiagnosticsSection(
                title: "System",
                entries: [
                    DiagnosticsEntry(
                        "macOS",
                        processInfo.operatingSystemVersionString
                    ),
                    DiagnosticsEntry(
                        "Architecture",
                        Self.processArchitecture
                    ),
                    DiagnosticsEntry(
                        "Physical Memory",
                        physicalMemory
                    ),
                    DiagnosticsEntry(
                        "Processors",
                        String(processInfo.processorCount)
                    ),
                ]
            ),
            DiagnosticsSection(
                title: "Runtimes",
                entries: [
                    DiagnosticsEntry(
                        "Valid Count",
                        String(runtimes.count)
                    ),
                    DiagnosticsEntry(
                        "Selected",
                        selectedRuntimeID ?? "none"
                    ),
                    DiagnosticsEntry(
                        "Managed Installed",
                        String(
                            managedRuntimeSnapshot
                                .installations.count
                        )
                    ),
                    DiagnosticsEntry(
                        "Managed Active",
                        managedRuntimeSnapshot.activeRuntimeID
                            ?? "none"
                    ),
                    DiagnosticsEntry(
                        "Managed Previous",
                        managedRuntimeSnapshot.previousRuntimeID
                            ?? "none"
                    ),
                ] + runtimeEntries
            ),
            DiagnosticsSection(
                title: "Models and Profiles",
                entries: [
                    DiagnosticsEntry(
                        "Model Roots",
                        String(modelDirectories.count + 1)
                    ),
                    DiagnosticsEntry(
                        "Model Files",
                        String(localModels.count)
                    ),
                    DiagnosticsEntry(
                        "Model Bytes",
                        String(localModelByteCount)
                    ),
                    DiagnosticsEntry(
                        "Scan Issues",
                        String(
                            (modelScanSnapshot?.issues.count ?? 0)
                                + modelDirectoryIssues.count
                        )
                    ),
                    DiagnosticsEntry(
                        "Profiles",
                        String(profiles.count)
                    ),
                    DiagnosticsEntry(
                        "Selected Profile",
                        profile?.name ?? "none"
                    ),
                    DiagnosticsEntry(
                        "Selected mmproj",
                        profile?.model.mmprojPath == nil
                            ? "no"
                            : "yes"
                    ),
                    DiagnosticsEntry(
                        "Selected Draft",
                        profile?.model.draftPath == nil
                            ? "no"
                            : "yes"
                    ),
                ]
            ),
            DiagnosticsSection(
                title: "Downloads",
                entries: [
                    DiagnosticsEntry(
                        "Job Count",
                        String(modelDownloadSnapshot.jobs.count)
                    ),
                    DiagnosticsEntry(
                        "Active Job",
                        modelDownloadSnapshot.activeJobID?
                            .uuidString ?? "none"
                    ),
                    DiagnosticsEntry(
                        "Hugging Face Token",
                        isHuggingFaceTokenConfigured
                            ? "configured in Keychain"
                            : "not configured"
                    ),
                ] + downloadEntries
            ),
            DiagnosticsSection(
                title: "Server",
                entries: serverDiagnosticsEntries
            ),
            DiagnosticsSection(
                title: "Updates",
                entries: [
                    DiagnosticsEntry(
                        "LlamaDock App",
                        appUpdateDiagnosticSummary
                    ),
                    DiagnosticsEntry(
                        "llama.cpp Runtime",
                        runtimeUpdateDiagnosticSummary
                    ),
                ]
            ),
        ]
        return DiagnosticsReportBuilder().makeReport(
            product: "LlamaDock",
            version: appVersion,
            build: appBuild,
            generatedAt: generatedAt,
            sections: sections
        )
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private var serverDiagnosticsEntries:
        [DiagnosticsEntry]
    {
        var entries = [
            DiagnosticsEntry(
                "State",
                serverStateDiagnosticName
            ),
            DiagnosticsEntry(
                "Buffered Log Events",
                String(serverSnapshot.logs.count)
            ),
        ]
        if let run = serverSnapshot.run {
            entries.append(
                DiagnosticsEntry(
                    "PID",
                    String(run.processIdentifier)
                )
            )
            entries.append(
                DiagnosticsEntry(
                    "Runtime",
                    run.runtimeID
                )
            )
            entries.append(
                DiagnosticsEntry(
                    "Endpoint",
                    run.baseURL.absoluteString
                )
            )
        }
        return entries
    }

    private var serverStateDiagnosticName: String {
        switch serverSnapshot.state {
        case .stopped:
            "stopped"
        case .starting:
            "starting"
        case .ready:
            "ready"
        case .degraded:
            "degraded"
        case .failed:
            "failed"
        case .stopping:
            "stopping"
        }
    }

    private var appUpdateDiagnosticSummary: String {
        if let appUpdateCheck {
            return appUpdateCheck.isUpdateAvailable
                ? "update \(appUpdateCheck.release.version) available"
                : "up to date"
        }
        return appUpdateError == nil
            ? "not checked"
            : "check failed"
    }

    private var runtimeUpdateDiagnosticSummary: String {
        if let latestRuntimeRelease {
            return "latest \(latestRuntimeRelease.release.tag)"
        }
        return runtimeUpdateError == nil
            ? "not checked"
            : "check failed"
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

    private func persistSelectedProfileID() {
        if let selectedProfileID {
            userDefaults.set(
                selectedProfileID.uuidString,
                forKey: "selectedProfileID"
            )
        } else {
            userDefaults.removeObject(
                forKey: "selectedProfileID"
            )
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
        guard
            userDefaults.object(
                forKey: "automaticallyCheckRuntimeUpdates"
            ) as? Bool ?? true
        else {
            return
        }
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

    private func checkAppUpdatesIfDue() async {
        guard
            userDefaults.object(
                forKey: "automaticallyCheckAppUpdates"
            ) as? Bool ?? true
        else {
            return
        }
        if
            let lastCheck = userDefaults.object(
                forKey: "lastAppUpdateCheck"
            ) as? Date,
            Date().timeIntervalSince(lastCheck) < 86_400
        {
            return
        }
        await checkAppUpdates(reportErrors: false)
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
                        self.endServerModelSecurityScope()
                        return
                    }
                case .starting, .ready, .degraded, .stopping:
                    break
                }

                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func beginServerModelSecurityScope(
        for profile: LaunchProfile
    ) {
        endServerModelSecurityScope()
        let modelPaths = [
            profile.model.mainPath,
            profile.model.mmprojPath,
            profile.model.draftPath,
        ].compactMap { $0 }
        let roots = Set(
            modelPaths.compactMap { modelPath in
                let normalizedModelPath = normalizedPath(
                    modelPath,
                    directoryHint: .notDirectory
                )
                return modelDirectories
                    .map(\.url)
                    .filter {
                        path(
                            normalizedModelPath,
                            isInside: normalizedPath(
                                $0.path,
                                directoryHint: .isDirectory
                            )
                        )
                    }
                    .max { $0.path.count < $1.path.count }
            }
        )
        for root in roots
        where root.startAccessingSecurityScopedResource() {
            serverModelSecurityScopes.append(root)
        }
    }

    private func endServerModelSecurityScope() {
        for root in serverModelSecurityScopes {
            root.stopAccessingSecurityScopedResource()
        }
        serverModelSecurityScopes = []
    }

    private func normalizedPath(
        _ path: String,
        directoryHint: URL.DirectoryHint
    ) -> String {
        URL(
            filePath: path,
            directoryHint: directoryHint
        )
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
    }

    private func canonicalPath(
        _ path: String
    ) -> String {
        normalizedPath(
            path,
            directoryHint: .notDirectory
        )
    }

    private func path(
        _ candidate: String,
        isInside root: String
    ) -> Bool {
        candidate == root
            || candidate.hasPrefix(
                root.hasSuffix("/") ? root : root + "/"
            )
    }
}
