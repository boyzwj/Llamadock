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
    var isServerOperationInProgress = false
    var visibleError: String?

    private let runtimeDiscovery: RuntimeCandidateDiscovery
    private let runtimeProbe: RuntimeProbe
    private let profileStore: JSONProfileStore
    private let serverController: ServerProcessController
    private let userDefaults: UserDefaults
    private var didBootstrap = false
    private var serverMonitorTask: Task<Void, Never>?

    init(
        runtimeDiscovery: RuntimeCandidateDiscovery = RuntimeCandidateDiscovery(),
        runtimeProbe: RuntimeProbe = RuntimeProbe(),
        serverController: ServerProcessController = ServerProcessController(),
        userDefaults: UserDefaults = .standard
    ) {
        self.runtimeDiscovery = runtimeDiscovery
        self.runtimeProbe = runtimeProbe
        self.serverController = serverController
        self.userDefaults = userDefaults

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        let root = applicationSupport.appending(
            path: "Llamadock",
            directoryHint: .isDirectory
        )
        profileStore = JSONProfileStore(
            directory: ApplicationDirectories(root: root).profiles
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
            selectedRuntimeID = runtimes.first?.id
        }
        refreshCommandPreview()
    }

    func refreshRuntimes() async {
        isRefreshingRuntimes = true
        defer { isRefreshingRuntimes = false }

        let candidates = runtimeDiscovery.discover(
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
            selectedRuntimeID = validRuntimes.first?.id
        }
        refreshCommandPreview()
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
            visibleError = "Could not start llama-server: \(error)"
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
    }

    var selectedRuntime: RuntimeInstallation? {
        runtimes.first { $0.id == selectedRuntimeID }
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
