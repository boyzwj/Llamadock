import AppKit
import LlamadockCore
import SwiftUI

struct ServersView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale

    var body: some View {
        LlamaDockPage {
            LlamaDockPageHeader(
                "Service",
                subtitle: "Profile, endpoint, launch command, and lifecycle"
            )

            if let failure = appModel.serverFailureMessage {
                InlineNotice(failure, tone: .failed) {
                    recoveryAction
                }
            }

            ServiceHeroCard(
                status: appModel.serviceStatus,
                detail: serviceDescription,
                runtime: runtimeSummary,
                endpoint: endpoint,
                isOperationInProgress:
                    appModel.isServerOperationInProgress,
                canStart: appModel.canStartServer,
                canStop: appModel.canStopServer,
                canRestart: appModel.canRestartServer,
                startHelp: appModel.startServerBlockReason,
                start: {
                    Task { await appModel.startServer() }
                },
                stop: {
                    Task { await appModel.stopServer() }
                },
                restart: {
                    Task { await appModel.restartServer() }
                }
            )

            networkConfiguration
            endpointActions
            profileConfiguration
            launchCommand
        }
        .navigationTitle("Service")
    }

    @ViewBuilder
    private var recoveryAction: some View {
        if appModel.selectedRuntime == nil {
            Button("Open Runtime") {
                appModel.selectedSection = .runtimes
            }
        } else if appModel.profile == nil {
            Button("Open Models") {
                appModel.selectedSection = .models
            }
        } else {
            Button("Review Profile") {
                appModel.selectedSection = .models
            }
        }
    }

    private var networkConfiguration: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Network")
                    .font(.title2.bold())

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 24,
                    verticalSpacing: 12
                ) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Listen Address")
                                .font(.headline)
                            Text(
                                "Where llama-server accepts connections."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Picker(
                            "Listen Address",
                            selection: serviceHostBinding
                        ) {
                            ForEach(listenAddressOptions) { option in
                                Text(option.title)
                                    .tag(option.host)
                            }
                            if !isKnownListenAddress {
                                Text(appModel.serviceHost)
                                    .tag(appModel.serviceHost)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 250, alignment: .trailing)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Port")
                                .font(.headline)
                            Text(
                                "Default 39281. Valid range 1–65535."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        TextField(
                            "Port",
                            value: servicePortBinding,
                            format: .number
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 130)
                    }
                }

                Label(
                    appModel.serverSnapshot.run == nil
                        ? localized(
                            "These settings apply to every model profile."
                        )
                        : localized(
                            "Changes are saved globally. Restart the service to apply them."
                        ),
                    systemImage:
                        appModel.serverSnapshot.run == nil
                            ? "network"
                            : "arrow.clockwise.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var endpointActions: some View {
        SectionCard {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("API Endpoint")
                        .font(.headline)
                    Text(
                        endpoint
                            ?? localized(
                                "Available after the service starts."
                            )
                    )
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                Spacer()

                Button("Open WebUI", systemImage: "safari") {
                    if
                        let url =
                            appModel.serverSnapshot.run?.baseURL
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(!appModel.serviceStatus.isReachable)
                .help(
                    appModel.serviceStatus.isReachable
                        ? localized("Open the built-in llama-server WebUI.")
                        : localized(
                            "The WebUI is available when the service is ready."
                        )
                )

                Button(
                    "Copy API URL",
                    systemImage: "doc.on.doc"
                ) {
                    if let endpoint {
                        copy(endpoint)
                    }
                }
                .disabled(endpoint == nil)
            }
        }
    }

    private var profileConfiguration: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Launch Profile")
                        .font(.title2.bold())
                    Spacer()
                    Button("Edit Profile") {
                        appModel.selectedSection = .models
                    }
                }

                if let profile = appModel.profile {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 24,
                        verticalSpacing: 10
                    ) {
                        row("Profile", profile.name)
                        row(
                            "Model",
                            URL(filePath: profile.model.mainPath)
                                .lastPathComponent
                        )
                        row(
                            "Runtime",
                            runtimeSummary
                        )
                        row(
                            "Context",
                            profile.server.contextSize?
                                .formatted()
                                ?? localized("Runtime default")
                        )
                        row(
                            "GPU Layers",
                            profile.server.gpuLayers?
                                .formatted()
                                ?? localized("Runtime default")
                        )
                    }
                } else {
                    EmptyStateAction(
                        title: "No Launch Profile",
                        description:
                            "Choose a valid local GGUF model to create a launch profile.",
                        systemImage: "doc.badge.plus",
                        actionTitle: "Open Models"
                    ) {
                        appModel.selectedSection = .models
                    }
                }
            }
        }
    }

    private var launchCommand: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Generated Command")
                        .font(.title2.bold())
                    Spacer()
                    if let command = appModel.commandPreview {
                        Button(
                            "Copy Command",
                            systemImage: "doc.on.doc"
                        ) {
                            copy(command)
                        }
                    }
                }

                if let command = appModel.commandPreview {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                } else {
                    Label(
                        appModel.commandError
                            ?? localized(
                                "Choose a validated runtime and launch profile."
                            ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }

                HStack {
                    Button("View Logs", systemImage: "text.alignleft") {
                        appModel.selectedSection = .logs
                    }
                    Spacer()
                    Text(
                        "Arguments are passed directly to llama-server without a shell."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var endpoint: String? {
        (
            appModel.serverSnapshot.run?.baseURL
                ?? configuredBaseURL
        )?
            .appending(path: "v1")
            .absoluteString
    }

    private var configuredBaseURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = appModel.serviceHost
        components.port = Int(appModel.servicePort)
        return components.url
    }

    private var listenAddressOptions: [ListenAddressOption] {
        [
            ListenAddressOption(
                host: "127.0.0.1",
                title: "127.0.0.1 (Local only)"
            ),
            ListenAddressOption(
                host: "0.0.0.0",
                title: "0.0.0.0 (All networks)"
            ),
            ListenAddressOption(
                host: "localhost",
                title: "localhost"
            ),
        ]
    }

    private var isKnownListenAddress: Bool {
        listenAddressOptions.contains {
            $0.host == appModel.serviceHost
        }
    }

    private var serviceHostBinding: Binding<String> {
        Binding(
            get: { appModel.serviceHost },
            set: { appModel.updateServiceHost($0) }
        )
    }

    private var servicePortBinding: Binding<Int> {
        Binding(
            get: { Int(appModel.servicePort) },
            set: { appModel.updateServicePort($0) }
        )
    }

    private var runtimeSummary: String {
        guard let runtime = appModel.selectedRuntime else {
            return localized("Runtime not configured")
        }
        return runtime.versionOutput
            .split(separator: "\n")
            .first
            .map(String.init)
            ?? runtime.source.rawValue
    }

    private var serviceDescription: String {
        if let failure = appModel.serverFailureMessage {
            return failure
        }
        switch appModel.serverSnapshot.state {
        case .stopped:
            return appModel.startServerBlockReason
                ?? localized(
                    "Runtime and profile are ready to start."
                )
        case .starting:
            return localized(
                "Waiting for the health endpoint to become ready."
            )
        case .ready:
            return localized(
                "The local API and WebUI are ready."
            )
        case .degraded(let reason):
            return localized("Health check degraded: \(reason)")
        case .failed(let reason):
            return localized("The service failed: \(reason)")
        case .stopping:
            return localized(
                "Stopping the owned llama-server process."
            )
        }
    }

    private func row(
        _ title: LocalizedStringKey,
        _ value: String
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct ListenAddressOption: Identifiable {
    let host: String
    let title: LocalizedStringKey

    var id: String { host }
}

struct ControlPlaneSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 18) {
                    Text("Settings")
                        .font(.largeTitle.bold())

                    Spacer()

                    Picker(
                        "Settings Area",
                        selection: $appModel.selectedSettingsTab
                    ) {
                        ForEach(ControlPlaneSettingsTab.allCases) {
                            Label($0.title, systemImage: $0.systemImage)
                                .tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }

                Text(
                    "Server defaults and individual model behavior"
                )
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, LlamaDockLayout.pagePadding)
            .padding(.vertical, 14)

            Divider()

            switch appModel.selectedSettingsTab {
            case .global:
                GlobalRouterSettingsView()
            case .models:
                ModelsView(mode: .settings)
            }
        }
        .navigationTitle("Settings")
    }
}

private struct GlobalRouterSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if appModel.serverSnapshot.run != nil {
                    InlineNotice(
                        "Global changes are saved immediately and apply after the router is restarted."
                    )
                }

                networkCard
                modelMemoryDefaultsCard
                modelThroughputDefaultsCard
                routerCard
                runtimeCard
                generatedConfigurationCard
            }
            .padding(LlamaDockLayout.pagePadding)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var modelMemoryDefaultsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    settingsHeader(
                        "Global Model Defaults",
                        subtitle:
                            "Shared by every model unless its model settings provide an override."
                    )

                    Spacer(minLength: 12)

                    if appModel.globalModelOptions != GlobalModelOptions() {
                        Button("Restore Safe Defaults") {
                            appModel.restoreGlobalModelDefaults()
                        }
                        .controlSize(.small)
                    }
                }

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 28,
                    verticalSpacing: 14
                ) {
                    GridRow {
                        fieldLabel(
                            "Context Size",
                            detail:
                                "Maximum shared KV context per loaded model. Range: 1K–1M tokens.",
                            flag: "--ctx-size"
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Slider(
                                    value: contextSizeBinding,
                                    in: Double(
                                        GlobalModelOptions.minimumContextSize
                                    )...Double(
                                        GlobalModelOptions.maximumContextSize
                                    ),
                                    step: Double(
                                        GlobalModelOptions.contextSizeStep
                                    )
                                )
                                Text(formattedTokenCount(
                                    appModel.globalModelOptions.contextSize
                                ))
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 112, alignment: .trailing)
                            }
                            HStack {
                                Text("1K")
                                Spacer()
                                Text("1M")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .frame(width: 390)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "K Cache Type",
                            detail:
                                "Key-cache precision. Lower-bit types save memory at some quality cost.",
                            flag: "--cache-type-k"
                        )

                        kvCacheTypePicker(
                            "K Cache Type",
                            selection: cacheTypeKBinding
                        )
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "V Cache Type",
                            detail:
                                "Value-cache precision. q8_0 is the memory-safe default.",
                            flag: "--cache-type-v"
                        )

                        kvCacheTypePicker(
                            "V Cache Type",
                            selection: cacheTypeVBinding
                        )
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "GPU Layers",
                            detail:
                                "Let llama.cpp choose, offload all layers, or keep model layers on CPU.",
                            flag: "--n-gpu-layers"
                        )

                        Picker("GPU Layers", selection: gpuLayersBinding) {
                            ForEach(GPULayersMode.allCases, id: \.rawValue) {
                                Text(gpuLayersTitle($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "KV Cache Offload",
                            detail:
                                "Keep KV cache compute on the GPU when supported.",
                            flag: "--kv-offload"
                        )

                        Toggle(
                            "Enable KV cache offload",
                            isOn: kvOffloadBinding
                        )
                        .labelsHidden()
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "Fit to Available Memory",
                            detail:
                                "Allow llama.cpp to tune automatic options to preserve a free-memory margin.",
                            flag: "--fit"
                        )

                        Toggle(
                            "Enable memory fitting",
                            isOn: fitToMemoryBinding
                        )
                        .labelsHidden()
                    }

                    if appModel.globalModelOptions.fitToMemory {
                        Divider()
                            .gridCellColumns(2)

                        GridRow {
                            fieldLabel(
                                "Free-memory Target",
                                detail:
                                    "Memory margin llama.cpp tries to leave available on each device.",
                                flag: "--fit-target"
                            )

                            Stepper(
                                value: fitTargetBinding,
                                in: 0...16_384,
                                step: 256
                            ) {
                                Text(
                                    "\(appModel.globalModelOptions.fitTargetMiB) MiB"
                                )
                                .font(.system(.body, design: .monospaced))
                            }
                            .frame(width: 220)
                        }

                        Divider()
                            .gridCellColumns(2)

                        GridRow {
                            fieldLabel(
                                "Minimum Fit Context",
                                detail:
                                    "Lowest context llama.cpp may choose while fitting memory.",
                                flag: "--fit-ctx"
                            )

                            HStack(spacing: 10) {
                                Slider(
                                    value: fitContextSizeBinding,
                                    in: Double(
                                        GlobalModelOptions.minimumContextSize
                                    )...Double(
                                        appModel.globalModelOptions.contextSize
                                    ),
                                    step: Double(
                                        GlobalModelOptions.contextSizeStep
                                    )
                                )
                                Text(formattedTokenCount(
                                    appModel.globalModelOptions.fitContextSize
                                ))
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 112, alignment: .trailing)
                            }
                            .frame(width: 390)
                        }
                    }
                }
            }
        }
    }

    private var modelThroughputDefaultsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader(
                    "Global Performance Defaults",
                    subtitle:
                        "Common llama.cpp scheduling and prompt-processing settings."
                )

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 28,
                    verticalSpacing: 14
                ) {
                    GridRow {
                        fieldLabel(
                            "Flash Attention",
                            detail:
                                "Automatic is recommended; force a mode only for compatibility testing.",
                            flag: "--flash-attn"
                        )

                        Picker(
                            "Flash Attention",
                            selection: flashAttentionBinding
                        ) {
                            ForEach(
                                FlashAttentionMode.allCases,
                                id: \.rawValue
                            ) {
                                Text(flashAttentionTitle($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "CPU Threads",
                            detail:
                                "Generation worker threads. Automatic uses the runtime default.",
                            flag: "--threads"
                        )

                        Picker("CPU Threads", selection: threadsBinding) {
                            Text("Automatic").tag(-1)
                            ForEach(1...maximumThreadCount, id: \.self) {
                                Text(String($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "Parallel Slots",
                            detail:
                                "Concurrent inference slots sharing the configured context cache.",
                            flag: "--parallel"
                        )

                        Picker("Parallel Slots", selection: parallelBinding) {
                            Text("Automatic").tag(-1)
                            ForEach(1...16, id: \.self) {
                                Text(String($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "Batch Size",
                            detail:
                                "Logical maximum tokens processed in one prompt batch.",
                            flag: "--batch-size"
                        )

                        Picker("Batch Size", selection: batchSizeBinding) {
                            ForEach(batchSizeChoices, id: \.self) {
                                Text(String($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "Micro Batch Size",
                            detail:
                                "Physical compute batch; it cannot exceed the logical batch size.",
                            flag: "--ubatch-size"
                        )

                        Picker(
                            "Micro Batch Size",
                            selection: ubatchSizeBinding
                        ) {
                            ForEach(ubatchSizeChoices, id: \.self) {
                                Text(String($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader(
                    "Network",
                    subtitle:
                        "One endpoint shared by every configured model."
                )

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 28,
                    verticalSpacing: 14
                ) {
                    GridRow {
                        fieldLabel(
                            "Listen Address",
                            detail:
                                "Choose local-only access or expose the router to the network."
                        )

                        Picker(
                            "Listen Address",
                            selection: hostBinding
                        ) {
                            Text("127.0.0.1 (Local only)")
                                .tag("127.0.0.1")
                            Text("0.0.0.0 (All networks)")
                                .tag("0.0.0.0")
                            Text("localhost")
                                .tag("localhost")
                            if !knownHosts.contains(appModel.serviceHost) {
                                Text(appModel.serviceHost)
                                    .tag(appModel.serviceHost)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "Listen Port",
                            detail: "Valid range: 1–65535."
                        )

                        TextField(
                            "Port",
                            value: portBinding,
                            format: .number
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    }
                }
            }
        }
    }

    private var routerCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader(
                    "Multi-model Router",
                    subtitle:
                        "Control dynamic model loading for the single llama-server process."
                )

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 28,
                    verticalSpacing: 14
                ) {
                    GridRow {
                        fieldLabel(
                            "Maximum Loaded Models",
                            detail:
                                "Models allowed in memory at the same time. Use 0 for unlimited."
                        )

                        TextField(
                            "4",
                            value: maximumLoadedModelsBinding,
                            format: .number
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    }

                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        fieldLabel(
                            "Load on Request",
                            detail:
                                "Automatically load an available model when an API request selects it."
                        )

                        Toggle(
                            "Enable model autoload",
                            isOn: modelsAutoloadBinding
                        )
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private var runtimeCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader(
                    "Runtime",
                    subtitle:
                        "The selected llama-server must support multi-model presets."
                )

                Picker(
                    "llama.cpp Runtime",
                    selection: runtimeBinding
                ) {
                    Text("Choose Runtime")
                        .tag(nil as String?)
                    ForEach(appModel.runtimes) { runtime in
                        Text(runtime.versionOutput.split(
                            separator: "\n"
                        ).first.map(String.init) ?? runtime.id)
                            .tag(Optional(runtime.id))
                    }
                }

                if
                    let runtime = appModel.selectedRuntime,
                    runtime.capabilities.support(
                        for: "--models-preset"
                    ) == .unsupported
                {
                    InlineNotice(
                        "This runtime does not support --models-preset. Install or choose a newer llama.cpp runtime.",
                        tone: .failed
                    )
                }
            }
        }
    }

    private var generatedConfigurationCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsHeader(
                    "Generated Configuration",
                    subtitle:
                        "LlamaDock writes a fresh models.ini immediately before every start."
                )

                if let command = appModel.commandPreview {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)

                    Button("Copy Launch Command", systemImage: "doc.on.doc") {
                        copy(command)
                    }
                } else {
                    Label(
                        appModel.commandError
                            ?? "Choose a runtime and enable a model setting.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func settingsHeader(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldLabel(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        flag: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)

                Spacer(minLength: 8)

                if let flag {
                    CapabilitySupportBadge(
                        support: appModel.selectedRuntime?.capabilities.support(
                            for: flag
                        ) ?? .unknown
                    )
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { appModel.serviceHost },
            set: { appModel.updateServiceHost($0) }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { Int(appModel.servicePort) },
            set: { appModel.updateServicePort($0) }
        )
    }

    private var maximumLoadedModelsBinding: Binding<Int> {
        Binding(
            get: { appModel.maximumLoadedModels },
            set: { appModel.updateMaximumLoadedModels($0) }
        )
    }

    private var modelsAutoloadBinding: Binding<Bool> {
        Binding(
            get: { appModel.modelsAutoload },
            set: { appModel.updateModelsAutoload($0) }
        )
    }

    private var contextSizeBinding: Binding<Double> {
        Binding(
            get: { Double(appModel.globalModelOptions.contextSize) },
            set: { value in
                appModel.updateGlobalModelOptions {
                    $0.contextSize = Int(value)
                }
            }
        )
    }

    private var cacheTypeKBinding: Binding<KVCacheType> {
        Binding(
            get: { appModel.globalModelOptions.cacheTypeK },
            set: { value in
                appModel.updateGlobalModelOptions { $0.cacheTypeK = value }
            }
        )
    }

    private var cacheTypeVBinding: Binding<KVCacheType> {
        Binding(
            get: { appModel.globalModelOptions.cacheTypeV },
            set: { value in
                appModel.updateGlobalModelOptions { $0.cacheTypeV = value }
            }
        )
    }

    private var gpuLayersBinding: Binding<GPULayersMode> {
        Binding(
            get: { appModel.globalModelOptions.gpuLayers },
            set: { value in
                appModel.updateGlobalModelOptions { $0.gpuLayers = value }
            }
        )
    }

    private var kvOffloadBinding: Binding<Bool> {
        Binding(
            get: { appModel.globalModelOptions.kvOffload },
            set: { value in
                appModel.updateGlobalModelOptions { $0.kvOffload = value }
            }
        )
    }

    private var fitToMemoryBinding: Binding<Bool> {
        Binding(
            get: { appModel.globalModelOptions.fitToMemory },
            set: { value in
                appModel.updateGlobalModelOptions { $0.fitToMemory = value }
            }
        )
    }

    private var fitTargetBinding: Binding<Int> {
        Binding(
            get: { appModel.globalModelOptions.fitTargetMiB },
            set: { value in
                appModel.updateGlobalModelOptions { $0.fitTargetMiB = value }
            }
        )
    }

    private var fitContextSizeBinding: Binding<Double> {
        Binding(
            get: { Double(appModel.globalModelOptions.fitContextSize) },
            set: { value in
                appModel.updateGlobalModelOptions {
                    $0.fitContextSize = Int(value)
                }
            }
        )
    }

    private var flashAttentionBinding: Binding<FlashAttentionMode> {
        Binding(
            get: { appModel.globalModelOptions.flashAttention },
            set: { value in
                appModel.updateGlobalModelOptions {
                    $0.flashAttention = value
                }
            }
        )
    }

    private var threadsBinding: Binding<Int> {
        Binding(
            get: { appModel.globalModelOptions.threads },
            set: { value in
                appModel.updateGlobalModelOptions { $0.threads = value }
            }
        )
    }

    private var parallelBinding: Binding<Int> {
        Binding(
            get: { appModel.globalModelOptions.parallel },
            set: { value in
                appModel.updateGlobalModelOptions { $0.parallel = value }
            }
        )
    }

    private var batchSizeBinding: Binding<Int> {
        Binding(
            get: { appModel.globalModelOptions.batchSize },
            set: { value in
                appModel.updateGlobalModelOptions { $0.batchSize = value }
            }
        )
    }

    private var ubatchSizeBinding: Binding<Int> {
        Binding(
            get: { appModel.globalModelOptions.ubatchSize },
            set: { value in
                appModel.updateGlobalModelOptions { $0.ubatchSize = value }
            }
        )
    }

    private var runtimeBinding: Binding<String?> {
        Binding(
            get: { appModel.selectedRuntimeID },
            set: { appModel.selectRuntime($0) }
        )
    }

    private var knownHosts: Set<String> {
        ["127.0.0.1", "0.0.0.0", "localhost"]
    }

    private var maximumThreadCount: Int {
        min(max(ProcessInfo.processInfo.processorCount, 1), 64)
    }

    private var batchSizeChoices: [Int] {
        [128, 256, 512, 1_024, 2_048, 4_096, 8_192]
    }

    private var ubatchSizeChoices: [Int] {
        [32, 64, 128, 256, 512, 1_024, 2_048, 4_096, 8_192]
            .filter { $0 <= appModel.globalModelOptions.batchSize }
    }

    private func kvCacheTypePicker(
        _ title: LocalizedStringKey,
        selection: Binding<KVCacheType>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(KVCacheType.allCases, id: \.rawValue) {
                Text($0.rawValue).tag($0)
            }
        }
        .labelsHidden()
        .frame(width: 220)
    }

    private func gpuLayersTitle(_ mode: GPULayersMode) -> LocalizedStringKey {
        switch mode {
        case .automatic:
            "Automatic"
        case .all:
            "All layers"
        case .cpuOnly:
            "CPU only"
        }
    }

    private func flashAttentionTitle(
        _ mode: FlashAttentionMode
    ) -> LocalizedStringKey {
        switch mode {
        case .automatic:
            "Automatic"
        case .enabled:
            "On"
        case .disabled:
            "Off"
        }
    }

    private func formattedTokenCount(_ value: Int) -> String {
        let shorthand: String
        if value == GlobalModelOptions.maximumContextSize {
            shorthand = "1M"
        } else if value.isMultiple(of: 1_024) {
            shorthand = "\(value / 1_024)K"
        } else {
            shorthand = value.formatted()
        }
        return "\(shorthand) (\(value.formatted()))"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            value,
            forType: .string
        )
    }
}

enum ControlPlaneSettingsTab:
    String,
    CaseIterable,
    Identifiable
{
    case global
    case models

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .global:
            "Server"
        case .models:
            "Models"
        }
    }

    var systemImage: String {
        switch self {
        case .global:
            "network"
        case .models:
            "slider.horizontal.3"
        }
    }
}

#Preview {
    ControlPlaneSettingsView()
        .environment(AppModel())
        .frame(width: 900, height: 700)
}
