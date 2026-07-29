import AppKit
import LlamadockCore
import SwiftUI

struct RuntimesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Group {
            if appModel.isRefreshingRuntimes && appModel.runtimeReports.isEmpty {
                ProgressView("Detecting llama.cpp runtimes…")
            } else if appModel.runtimeReports.isEmpty {
                ContentUnavailableView(
                    "No Runtimes",
                    systemImage: "shippingbox",
                    description: Text(
                        "Install llama.cpp with Homebrew or add a custom llama-server executable."
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
                            isActive: appModel.selectedRuntimeID
                                == report.candidate.id
                        )
                        .tag(report.candidate.id)
                    }
                }
                .onChange(of: appModel.selectedRuntimeID) {
                    appModel.selectRuntime(appModel.selectedRuntimeID)
                }
            }
        }
        .navigationTitle("Runtimes")
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appModel.refreshRuntimes() }
                }
                .disabled(appModel.isRefreshingRuntimes)

                Button("Add Custom Runtime", systemImage: "plus") {
                    chooseCustomRuntime()
                }
            }
        }
    }

    private func chooseCustomRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Choose llama-server or llama"
        panel.message = "LlamaDock will inspect this executable but never overwrite it."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task { await appModel.addCustomRuntime(url) }
    }
}

private struct RuntimeReportRow: View {
    let report: RuntimeProbeReport
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    sourceTitle,
                    systemImage: report.candidate.source == .homebrew
                        ? "mug"
                        : "wrench.and.screwdriver"
                )
                .font(.headline)

                if isActive {
                    Text("Active")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
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
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
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
}

#Preview {
    RuntimesView()
        .environment(AppModel())
        .frame(width: 800, height: 600)
}
