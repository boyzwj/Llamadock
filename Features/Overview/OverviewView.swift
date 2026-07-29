import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Overview")
                    .font(.largeTitle.bold())

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                    spacing: 16
                ) {
                    SummaryCard(
                        title: "Runtime",
                        value: runtimeSummary,
                        systemImage: "shippingbox"
                    )
                    SummaryCard(
                        title: "Models",
                        value: modelSummary,
                        systemImage: "externaldrive"
                    )
                    SummaryCard(
                        title: "Server",
                        value: serverSummary,
                        systemImage: "server.rack"
                    )
                }

                ContentUnavailableView {
                    Label("Local llama.cpp Control Plane", systemImage: "sparkles")
                } description: {
                    Text(
                        setupDescription
                    )
                } actions: {
                    if appModel.selectedRuntime == nil {
                        Button("Open Runtimes") {
                            appModel.selectedSection = .runtimes
                        }
                    } else if appModel.profile == nil {
                        Button("Open Models") {
                            appModel.selectedSection = .models
                        }
                    } else {
                        Button("Open Servers") {
                            appModel.selectedSection = .servers
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
            .padding(28)
        }
        .navigationTitle("Overview")
    }

    private var runtimeSummary: String {
        guard let runtime = appModel.selectedRuntime else {
            return "Not configured"
        }
        return runtime.versionOutput
            .split(separator: "\n")
            .first
            .map(String.init) ?? runtime.source.rawValue
    }

    private var serverSummary: String {
        switch appModel.serverSnapshot.state {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .ready:
            "Ready"
        case .degraded:
            "Degraded"
        case .failed:
            "Failed"
        case .stopping:
            "Stopping"
        }
    }

    private var modelSummary: String {
        let count = appModel.localModels.count
        guard count > 0 else {
            return "No local models"
        }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(
                min(
                    appModel.localModelByteCount,
                    UInt64(Int64.max)
                )
            ),
            countStyle: .file
        )
        return "\(count) \(count == 1 ? "file" : "files") • \(size)"
    }

    private var setupDescription: String {
        if appModel.selectedRuntime == nil {
            return "Add or install a llama.cpp runtime to begin."
        }
        if appModel.profile == nil {
            return "Choose a local GGUF model and create its launch profile."
        }
        return "Review the generated command, then start the owned llama-server process."
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(value)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

#Preview {
    OverviewView()
        .environment(AppModel())
        .frame(width: 800, height: 600)
}
