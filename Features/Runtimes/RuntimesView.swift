import AppKit
import LlamadockCore
import SwiftUI

struct RuntimesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 0) {
            managedRuntimePanel
            Divider()

            Group {
                if
                    appModel.isRefreshingRuntimes
                        && appModel.runtimeReports.isEmpty
                {
                    ProgressView("Detecting llama.cpp runtimes…")
                } else if appModel.runtimeReports.isEmpty {
                    ContentUnavailableView(
                        "No Validated Runtimes",
                        systemImage: "shippingbox",
                        description: Text(
                            """
                            Install the latest managed runtime above, or add \
                            an existing llama-server executable.
                            """
                        )
                    )
                } else {
                    List(selection: $appModel.selectedRuntimeID) {
                        ForEach(
                            appModel.runtimeReports,
                            id: \.candidate.id
                        ) { report in
                            RuntimeReportRow(
                                report: report,
                                isActive: appModel
                                    .managedRuntimeSnapshot
                                    .activeRuntimeID
                                    == report.candidate.id,
                                isPrevious: appModel
                                    .managedRuntimeSnapshot
                                    .previousRuntimeID
                                    == report.candidate.id
                            )
                            .tag(report.candidate.id)
                        }
                    }
                    .onChange(of: appModel.selectedRuntimeID) {
                        appModel.selectRuntime(
                            appModel.selectedRuntimeID
                        )
                    }
                }
            }
        }
        .navigationTitle("Runtimes")
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await appModel.refreshRuntimes()
                    }
                }
                .disabled(appModel.isRefreshingRuntimes)

                Button(
                    "Add Custom Runtime",
                    systemImage: "plus"
                ) {
                    chooseCustomRuntime()
                }
            }
        }
    }

    private var managedRuntimePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Managed llama.cpp")
                        .font(.headline)
                    Text(managedRuntimeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                if
                    appModel.isCheckingRuntimeUpdates
                        || appModel.isInstallingRuntime
                {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let latest = appModel.latestRuntimeRelease {
                HStack(spacing: 8) {
                    Label(
                        "Latest \(latest.release.tag)",
                        systemImage: "sparkles"
                    )
                    .font(.caption)

                    Text(latestSourceTitle(latest.source))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appModel.isLatestManagedRuntimeInstalled {
                        Text("Installed")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
            }

            if let warning = appModel.latestRuntimeRelease?.warning {
                Label(
                    warning,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }

            if let error = appModel.runtimeUpdateError {
                Label(
                    error,
                    systemImage: "wifi.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }

            if appModel.runtimeInstallSnapshot.state != .idle {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        installStateTitle(
                            appModel.runtimeInstallSnapshot.state
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(
                        installStateIsFailure
                            ? Color.red
                            : Color.secondary
                    )
                    .textSelection(.enabled)

                    Spacer()

                    if installStateIsFailure {
                        Button("Copy Diagnostics") {
                            copyInstallDiagnostics()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            HStack {
                Button("Check Updates") {
                    Task {
                        await appModel.checkRuntimeUpdates()
                    }
                }
                .disabled(
                    appModel.isCheckingRuntimeUpdates
                        || appModel.isInstallingRuntime
                )

                Button(
                    appModel.isLatestManagedRuntimeInstalled
                        ? "Latest Installed"
                        : "Install & Activate"
                ) {
                    Task {
                        await appModel.installLatestRuntime()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    appModel.isInstallingRuntime
                        || !appModel.canChangeManagedRuntime
                        || appModel.isLatestManagedRuntimeInstalled
                )

                Button("Activate Selected") {
                    Task {
                        await appModel
                            .activateSelectedManagedRuntime()
                    }
                }
                .disabled(
                    appModel.selectedManagedRuntimeID == nil
                        || appModel.selectedManagedRuntimeID
                            == appModel.managedRuntimeSnapshot
                                .activeRuntimeID
                        || appModel.isInstallingRuntime
                        || !appModel.canChangeManagedRuntime
                )

                Button("Roll Back") {
                    Task {
                        await appModel.rollbackManagedRuntime()
                    }
                }
                .disabled(
                    appModel.managedRuntimeSnapshot
                        .previousRuntimeID == nil
                        || appModel.isInstallingRuntime
                        || !appModel.canChangeManagedRuntime
                )

                Spacer()
            }
        }
        .padding(16)
        .background(.background.secondary)
    }

    private var managedRuntimeSummary: String {
        let snapshot = appModel.managedRuntimeSnapshot
        guard
            let activeID = snapshot.activeRuntimeID,
            let active = snapshot.installations.first(
                where: { $0.id == activeID }
            )
        else {
            return snapshot.installations.isEmpty
                ? "No managed runtime installed"
                : "\(snapshot.installations.count) installed, none active"
        }

        if
            let previousID = snapshot.previousRuntimeID,
            let previous = snapshot.installations.first(
                where: { $0.id == previousID }
            )
        {
            return """
                Active \(active.tag) · Previous \(previous.tag) · \
                \(snapshot.installations.count) installed
                """
        }
        return """
            Active \(active.tag) · \
            \(snapshot.installations.count) installed
            """
    }

    private var installStateIsFailure: Bool {
        if case .failed = appModel.runtimeInstallSnapshot.state {
            return true
        }
        return false
    }

    private func installStateTitle(
        _ state: ManagedRuntimeInstallState
    ) -> String {
        switch state {
        case .idle:
            "Ready to install"
        case .fetchingRelease:
            "Fetching the latest official release…"
        case .downloading(let tag):
            "Downloading \(tag)…"
        case .verifyingArchive:
            "Verifying archive size and checksum…"
        case .extracting:
            "Safely extracting the archive…"
        case .validatingBinaries:
            "Validating architecture and binaries…"
        case .registering:
            "Registering the managed runtime…"
        case .activating:
            "Activating the managed runtime…"
        case .ready(let record):
            "\(record.tag) installed and ready"
        case .failed(let stage, let reason):
            "Failed during \(stage.rawValue): \(reason)"
        }
    }

    private func latestSourceTitle(
        _ source: RuntimeReleaseCheckSource
    ) -> String {
        switch source {
        case .network:
            "from GitHub"
        case .notModifiedCache:
            "validated cache"
        case .staleCache:
            "offline cache"
        }
    }

    private func copyInstallDiagnostics() {
        let snapshot = appModel.runtimeInstallSnapshot
        let transitions = snapshot.transitions
            .map { String(describing: $0) }
            .joined(separator: "\n")
        let diagnostics = """
            LlamaDock managed runtime installer
            State: \(String(describing: snapshot.state))
            Transitions:
            \(transitions)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            diagnostics,
            forType: .string
        )
    }

    private func chooseCustomRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Choose llama-server or llama"
        panel.message = """
            LlamaDock will inspect this executable but never overwrite it.
            """
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            await appModel.addCustomRuntime(url)
        }
    }
}

private struct RuntimeReportRow: View {
    let report: RuntimeProbeReport
    let isActive: Bool
    let isPrevious: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    sourceTitle,
                    systemImage: sourceSystemImage
                )
                .font(.headline)

                if isActive {
                    Text("Active")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            .tint.opacity(0.15),
                            in: Capsule()
                        )
                }

                if isPrevious {
                    Text("Previous")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            .secondary.opacity(0.12),
                            in: Capsule()
                        )
                }

                Spacer()
                validationLabel
            }

            if let version = report.serverVersionOutput {
                Text(version)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Text(
                report.candidate.serverURL?.path
                    ?? "llama-server executable missing"
            )
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            if let capabilities = report.capabilities {
                Text(
                    capabilities.detection == .detected
                        ? "\(capabilities.supportedFlags.count) flags detected"
                        : "Capabilities unknown"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let warning = report.warning {
                Label(
                    warning,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if case .invalid(let reason) = report.validation {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .frame(
            maxWidth: .infinity,
            minHeight: 88,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch report.validation {
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let reason):
            Label("Invalid", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(reason)
        }
    }

    private var sourceTitle: String {
        switch report.candidate.source {
        case .managed:
            "Managed"
        case .officialInstaller:
            "Official Installer"
        case .homebrew:
            "Homebrew"
        case .custom:
            "Custom"
        }
    }

    private var sourceSystemImage: String {
        switch report.candidate.source {
        case .managed:
            "shippingbox.fill"
        case .officialInstaller:
            "square.and.arrow.down"
        case .homebrew:
            "mug"
        case .custom:
            "wrench.and.screwdriver"
        }
    }
}

#Preview {
    RuntimesView()
        .environment(AppModel())
        .frame(width: 800, height: 600)
}
