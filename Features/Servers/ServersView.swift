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

#Preview {
    ServersView()
        .environment(AppModel())
        .frame(width: 900, height: 700)
}
