import AppKit
import LlamadockCore
import SwiftUI

struct ServersView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            serverHeader
                .padding(24)

            Divider()

            if appModel.serverSnapshot.logs.isEmpty {
                ContentUnavailableView(
                    "No Server Logs",
                    systemImage: "text.alignleft",
                    description: Text(
                        "stdout and stderr from the owned llama-server process will appear here."
                    )
                )
            } else {
                logView
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItemGroup {
                Button("Start", systemImage: "play.fill") {
                    Task { await appModel.startServer() }
                }
                .disabled(!appModel.canStartServer)

                Button("Stop", systemImage: "stop.fill") {
                    Task { await appModel.stopServer() }
                }
                .disabled(!appModel.canStopServer)

                Button("Restart", systemImage: "arrow.clockwise") {
                    Task { await appModel.restartServer() }
                }
                .disabled(!appModel.canRestartServer)
            }
        }
    }

    private var serverHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: stateSystemImage)
                .font(.system(size: 32))
                .foregroundStyle(stateColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(stateTitle)
                    .font(.title2.bold())

                if let run = appModel.serverSnapshot.run {
                    LabeledContent("PID", value: String(run.processIdentifier))
                    LabeledContent("API Base URL") {
                        Text(run.baseURL.appending(path: "v1").absoluteString)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Runtime", value: run.runtimeID)

                    serverMetrics(for: run)

                    HStack {
                        Button("Open WebUI", systemImage: "safari") {
                            NSWorkspace.shared.open(run.baseURL)
                        }
                        .disabled(
                            appModel.serverSnapshot.state != .ready
                                && !isDegraded
                        )

                        Button("Copy API URL", systemImage: "doc.on.doc") {
                            copy(
                                run.baseURL.appending(path: "v1").absoluteString
                            )
                        }

                        Button("Copy Launch Command", systemImage: "terminal") {
                            copy(run.command.displayCommand)
                        }
                    }
                } else {
                    Text(
                        "Choose a validated runtime and a local GGUF model before starting."
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if appModel.isServerOperationInProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Server operation in progress")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Owned server status")
    }

    @ViewBuilder
    private func serverMetrics(
        for run: ServerRun
    ) -> some View {
        if let metrics = appModel.serverSnapshot.metrics {
            HStack(spacing: 24) {
                LabeledContent(
                    "CPU",
                    value: metrics.cpuPercent.map {
                        String(format: "%.1f%%", $0)
                    } ?? "Sampling"
                )
                LabeledContent(
                    "Memory",
                    value: formattedBytes(
                        metrics.residentMemoryBytes
                    )
                )
                LabeledContent(
                    "Threads",
                    value: String(metrics.threadCount)
                )
                LabeledContent(
                    "Uptime",
                    value: formattedUptime(
                        since: run.processStartTime
                    )
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server performance")
        }
    }

    private var logView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(appModel.serverSnapshot.logs) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.timestamp, format: .dateTime
                            .hour()
                            .minute()
                            .second()
                        )
                        .foregroundStyle(.tertiary)

                        Text(event.source == .standardError ? "ERR" : "OUT")
                            .foregroundStyle(
                                event.source == .standardError
                                    ? .orange
                                    : .secondary
                            )

                        Text(event.message)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(.black.opacity(0.03))
        .accessibilityLabel("Server log")
    }

    private var stateTitle: String {
        switch appModel.serverSnapshot.state {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .ready:
            "Ready"
        case .degraded(let reason):
            "Degraded — \(reason)"
        case .failed(let reason):
            "Failed — \(reason)"
        case .stopping:
            "Stopping"
        }
    }

    private var stateSystemImage: String {
        switch appModel.serverSnapshot.state {
        case .stopped:
            "stop.circle"
        case .starting, .stopping:
            "clock.arrow.circlepath"
        case .ready:
            "checkmark.circle.fill"
        case .degraded:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch appModel.serverSnapshot.state {
        case .stopped:
            .secondary
        case .starting, .stopping:
            .blue
        case .ready:
            .green
        case .degraded:
            .orange
        case .failed:
            .red
        }
    }

    private var isDegraded: Bool {
        if case .degraded = appModel.serverSnapshot.state {
            return true
        }
        return false
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(
                min(bytes, UInt64(Int64.max))
            ),
            countStyle: .memory
        )
    }

    private func formattedUptime(since start: Date) -> String {
        let totalSeconds = max(
            Int(Date().timeIntervalSince(start)),
            0
        )
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }
        return String(
            format: "%d:%02d",
            minutes,
            seconds
        )
    }
}

#Preview {
    ServersView()
        .environment(AppModel())
        .frame(width: 900, height: 700)
}
