import AppKit
import LlamadockCore
import SwiftUI

struct ServiceMenuBarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    let presentMainWindow: () -> Void

    init(
        presentMainWindow: @escaping () -> Void = {}
    ) {
        self.presentMainWindow = presentMainWindow
    }

    var body: some View {
        statusHeader

        LabeledContent(
            "Model Settings",
            value: String(
                format: localized("%lld enabled"),
                Int64(appModel.enabledRouterProfiles.count)
            )
        )

        LabeledContent(
            "Loaded Models",
            value: appModel.serverSnapshot.run == nil
                ? "—"
                : "\(appModel.loadedServerModelCount)"
        )

        LabeledContent(
            "API",
            value: appModel.serverSnapshot.run.map {
                $0.baseURL
                    .appending(path: "v1")
                    .absoluteString
            } ?? "—"
        )

        LabeledContent(
            "Uptime",
            value: appModel.serverSnapshot.run.map {
                formattedUptime(
                    since: $0.processStartTime,
                    now: Date()
                )
            } ?? "—"
        )

        Divider()

        Button("Start Server", systemImage: "play.fill") {
            Task {
                await appModel.startServer()
            }
        }
        .disabled(!appModel.canStartServer)
        .help(
            appModel.startServerBlockReason
                ?? localized("Start the configured multi-model router.")
        )

        Button("Stop Server", systemImage: "stop.fill") {
            Task {
                await appModel.stopServer()
            }
        }
        .disabled(!appModel.canStopServer)
        .help(
            appModel.canStopServer
                ? localized("Stop the owned llama-server process.")
                : localized("No owned server can be stopped.")
        )

        Button(
            "Restart Server",
            systemImage: "arrow.clockwise"
        ) {
            Task {
                await appModel.restartServer()
            }
        }
        .disabled(!appModel.canRestartServer)
        .help(
            appModel.canRestartServer
                ? localized("Restart the owned llama-server process.")
                : localized("The server is not ready to restart.")
        )

        Divider()

        Button("Open WebUI", systemImage: "safari") {
            if let url = appModel.serverSnapshot.run?.baseURL {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(!appModel.serviceStatus.isReachable)

        Button("Copy API URL", systemImage: "doc.on.doc") {
            guard
                let value = appModel.serverSnapshot.run?
                    .baseURL
                    .appending(path: "v1")
                    .absoluteString
            else {
                return
            }
            copy(value)
        }
        .disabled(appModel.serverSnapshot.run == nil)

        Divider()

        Button("Dashboard", systemImage: "gauge.with.dots.needle.67percent") {
            appModel.selectedSection = .overview
            presentMainWindow()
        }
        .keyboardShortcut("d", modifiers: [.command])

        Divider()

        Button("Quit LlamaDock") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var statusHeader: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.serviceStatus.localizedTitle)
                    .font(.headline)
                Text(runtimeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(
                systemName: appModel.serviceStatus.systemImage
            )
            .foregroundStyle(appModel.serviceStatus.tone.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Owned server status: \(appModel.serviceStatus.localizedString(locale: locale))"
        )
    }

    private var runtimeTitle: String {
        guard let runtime = appModel.selectedRuntime else {
            return localized("Runtime not configured")
        }
        return runtime.versionOutput
            .split(separator: "\n")
            .first
            .map(String.init)
            ?? runtime.source.rawValue
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func formattedUptime(
        since start: Date,
        now: Date
    ) -> String {
        let seconds = max(
            Int(now.timeIntervalSince(start)),
            0
        )
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

#Preview {
    ServiceMenuBarView()
        .environment(AppModel())
}
