import AppKit
import LlamadockCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale

    var body: some View {
        LlamaDockPage {
            LlamaDockPageHeader(
                "Overview",
                subtitle: "Local llama.cpp service control"
            ) {
                if appModel.serviceStatus.isReachable {
                    Button("Copy API URL", systemImage: "doc.on.doc") {
                        if let endpoint {
                            copy(endpoint)
                        }
                    }
                }
            }

            if let failure = appModel.serverFailureMessage {
                InlineNotice(failure, tone: .failed) {
                    Button("Open Service") {
                        appModel.selectedSection = .service
                    }
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

            if needsSetup {
                FirstRunChecklist()
            }

            if let run = appModel.serverSnapshot.run {
                metrics(for: run)
            }

            currentConfiguration
            resourceSummary
            recentActivity
        }
        .navigationTitle("Overview")
    }

    private var needsSetup: Bool {
        appModel.selectedRuntime == nil
            || appModel.profile == nil
            || !selectedModelExists
    }

    private var selectedModelExists: Bool {
        appModel.profile.map {
            FileManager.default.fileExists(
                atPath: $0.model.mainPath
            )
        } ?? false
    }

    private var endpoint: String? {
        appModel.serverSnapshot.run?
            .baseURL
            .appending(path: "v1")
            .absoluteString
    }

    private var runtimeSummary: String {
        guard let runtime = appModel.selectedRuntime else {
            return localized("Runtime not configured")
        }
        return runtime.versionOutput
            .split(separator: "\n")
            .first
            .map(String.init) ?? runtime.source.rawValue
    }

    private var serviceDescription: String {
        if let failure = appModel.serverFailureMessage {
            return failure
        }
        switch appModel.serverSnapshot.state {
        case .stopped:
            return appModel.startServerBlockReason
                ?? localized(
                    "Runtime and profile are ready. Start the owned server when needed."
                )
        case .starting:
            return localized(
                "Waiting for llama-server health readiness."
            )
        case .ready:
            return localized(
                "The API and built-in WebUI are reachable."
            )
        case .degraded(let reason):
            return localized("Health check degraded: \(reason)")
        case .failed(let reason):
            return localized("The last start failed: \(reason)")
        case .stopping:
            return localized(
                "Stopping the owned llama-server process."
            )
        }
    }

    private func metrics(for run: ServerRun) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 150), spacing: 12),
            ],
            spacing: 12
        ) {
            MetricCard(
                title: "PID",
                value: String(run.processIdentifier),
                systemImage: "number"
            )
            MetricCard(
                title: "CPU",
                value: appModel.serverSnapshot.metrics?
                    .cpuPercent
                    .map { String(format: "%.1f%%", $0) }
                    ?? localized("Sampling"),
                systemImage: "cpu",
                tone: .active
            )
            MetricCard(
                title: "Resident Memory",
                value: appModel.serverSnapshot.metrics.map {
                    formattedBytes($0.residentMemoryBytes)
                } ?? localized("Sampling"),
                systemImage: "memorychip"
            )
            MetricCard(
                title: "Threads",
                value: appModel.serverSnapshot.metrics.map {
                    String($0.threadCount)
                } ?? localized("Sampling"),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            TimelineView(
                .periodic(from: .now, by: 1)
            ) { context in
                MetricCard(
                    title: "Uptime",
                    value: formattedUptime(
                        since: run.processStartTime,
                        now: context.date
                    ),
                    systemImage: "clock"
                )
            }
        }
    }

    private var currentConfiguration: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    "Current Configuration",
                    actionTitle: "Open Service",
                    destination: .service
                )

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 22,
                    verticalSpacing: 10
                ) {
                    configurationRow(
                        "Model",
                        appModel.profile.map {
                            URL(filePath: $0.model.mainPath)
                                .lastPathComponent
                        } ?? localized("Not configured")
                    )
                    configurationRow(
                        "Profile",
                        appModel.profile?.name
                            ?? localized("Not configured")
                    )
                    configurationRow(
                        "Context",
                        appModel.profile?
                            .server
                            .contextSize?
                            .formatted()
                            ?? localized("Runtime default")
                    )
                    configurationRow(
                        "Host / Port",
                        "\(appModel.serviceHost):\(appModel.servicePort)"
                    )
                }

                if let command = appModel.commandPreview {
                    Divider()
                    HStack(alignment: .top) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Spacer()
                        Button(
                            "Copy Command",
                            systemImage: "doc.on.doc"
                        ) {
                            copy(command)
                        }
                    }
                }
            }
        }
    }

    private var resourceSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resources")
                .font(.title2.bold())

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 190), spacing: 12),
                ],
                spacing: 12
            ) {
                resourceCard(
                    title: "Runtime",
                    value: runtimeSummary,
                    systemImage: "shippingbox",
                    destination: .runtimes
                )
                resourceCard(
                    title: "Model Library",
                    value: modelSummary,
                    systemImage: "externaldrive",
                    destination: .models
                )
                resourceCard(
                    title: "Downloads",
                    value: downloadSummary,
                    systemImage: "arrow.down.circle",
                    destination: .downloads
                )
            }
        }
    }

    private var recentActivity: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    "Recent Activity",
                    actionTitle: "View All Logs",
                    destination: .logs
                )

                if let recentError {
                    InlineNotice(
                        recentError.message,
                        tone: .failed
                    )
                }

                let events = Array(
                    appModel.serverSnapshot.logs.suffix(5)
                )
                if events.isEmpty {
                    Text("No recent server activity.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        HStack(
                            alignment: .firstTextBaseline,
                            spacing: 10
                        ) {
                            Text(
                                event.timestamp,
                                format: .dateTime
                                    .hour()
                                    .minute()
                                    .second()
                            )
                            .foregroundStyle(.tertiary)
                            Text(event.message)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }

    private var recentError: LogEvent? {
        appModel.serverSnapshot.logs.reversed().first {
            $0.inferredSeverity == .error
        }
    }

    private var modelSummary: String {
        guard !appModel.localModels.isEmpty else {
            return localized("No local models")
        }
        return localized(
            "\(appModel.localModels.count) local model files • \(formattedBytes(appModel.localModelByteCount))"
        )
    }

    private var downloadSummary: String {
        let jobs = appModel.modelDownloadSnapshot.jobs
        let active = jobs.filter {
            !$0.state.isTerminal && $0.state != .paused
        }.count
        guard !jobs.isEmpty else {
            return localized("No downloads")
        }
        return localized(
            "\(active) active downloads • \(jobs.count) total"
        )
    }

    private func resourceCard(
        title: LocalizedStringKey,
        value: String,
        systemImage: String,
        destination: AppSection
    ) -> some View {
        Button {
            appModel.selectedSection = destination
        } label: {
            SectionCard {
                HStack(spacing: 13) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(value)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(
        _ title: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        destination: AppSection
    ) -> some View {
        HStack {
            Text(title)
                .font(.title2.bold())
            Spacer()
            Button(actionTitle) {
                appModel.selectedSection = destination
            }
            .buttonStyle(.link)
        }
    }

    private func configurationRow(
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

    private func formattedBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max)))
        )
    }

    private func formattedUptime(
        since start: Date,
        now: Date
    ) -> String {
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, seconds % 60)
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct FirstRunChecklist: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Finish Setup")
                    .font(.title2.bold())
                Text(
                    "Complete the remaining steps to start a local API without using Terminal."
                )
                .foregroundStyle(.secondary)

                setupRow(
                    "1. Choose a Runtime",
                    isComplete: appModel.selectedRuntime != nil,
                    destination: .runtimes
                )
                setupRow(
                    "2. Choose a GGUF Model",
                    isComplete: appModel.profile != nil,
                    destination: .models
                )
                setupRow(
                    "3. Review the Profile",
                    isComplete:
                        appModel.profile != nil
                            && appModel.commandPreview != nil,
                    destination: .service
                )
                setupRow(
                    "4. Start the Service",
                    isComplete:
                        appModel.serviceStatus.isReachable,
                    destination: .service
                )
            }
        }
    }

    private func setupRow(
        _ title: LocalizedStringKey,
        isComplete: Bool,
        destination: AppSection
    ) -> some View {
        Button {
            appModel.selectedSection = destination
        } label: {
            HStack {
                Image(
                    systemName: isComplete
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .foregroundStyle(
                    isComplete ? .green : .secondary
                )
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            isComplete ? "Complete" : "Incomplete"
        )
    }
}

#Preview {
    OverviewView()
        .environment(AppModel())
        .frame(width: 900, height: 700)
}
