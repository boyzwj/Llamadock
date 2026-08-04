import AppKit
import LlamadockCore
import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @State private var filter = ServerLogFilter.all

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, LlamaDockLayout.pagePadding)
                .padding(.vertical, 18)

            Divider()

            if appModel.serverSnapshot.logs.isEmpty {
                EmptyStateAction(
                    title: "No Server Logs",
                    description:
                        "stdout and stderr from the owned llama-server process will appear here.",
                    systemImage: "text.alignleft",
                    actionTitle: "Open Dashboard"
                ) {
                    appModel.selectedSection = .overview
                }
            } else if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "No Matching Logs",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(
                        "Choose another severity filter to view buffered logs."
                    )
                )
            } else {
                logList
            }
        }
        .navigationTitle("Logs")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Logs")
                    .font(.largeTitle.bold())
                Text("Live output from the owned llama-server process")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Severity", selection: $filter) {
                ForEach(ServerLogFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .frame(width: 150)

            Button("Copy Visible", systemImage: "doc.on.doc") {
                copyVisibleLogs()
            }
            .disabled(filteredLogs.isEmpty)

            Button(
                "Clear",
                systemImage: "trash",
                role: .destructive
            ) {
                Task {
                    await appModel.clearServerLogs()
                }
            }
        }
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(filteredLogs) { event in
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 8
                    ) {
                        Text(
                            event.timestamp,
                            format: .dateTime
                                .hour()
                                .minute()
                                .second()
                        )
                        .foregroundStyle(.tertiary)

                        Text(logLabel(for: event))
                            .foregroundStyle(logColor(for: event))
                            .frame(width: 54, alignment: .leading)

                        Text(event.message)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
            }
            .padding(16)
        }
        .background(.black.opacity(0.035))
        .accessibilityLabel("Server log")
    }

    private var filteredLogs: [LogEvent] {
        appModel.serverSnapshot.logs.filter(filter.includes)
    }

    private func copyVisibleLogs() {
        let value = filteredLogs.map {
            "[\($0.timestamp.formatted(.iso8601))] "
                + "\(logLabel(for: $0)) \($0.message)"
        }
        .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func logLabel(for event: LogEvent) -> String {
        switch event.inferredSeverity {
        case .debug:
            localized("DEBUG")
        case .info:
            localized("INFO")
        case .warning:
            localized("WARN")
        case .error:
            localized("ERROR")
        case nil:
            switch event.source {
            case .standardOutput:
                "STDOUT"
            case .standardError:
                "STDERR"
            case .system:
                "SYSTEM"
            }
        }
    }

    private func logColor(for event: LogEvent) -> Color {
        switch event.inferredSeverity {
        case .error:
            .red
        case .warning:
            .orange
        case .debug:
            .gray
        case .info, nil:
            .secondary
        }
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private enum ServerLogFilter:
    String,
    CaseIterable,
    Identifiable
{
    case all
    case info
    case warnings
    case errors

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all:
            "All Logs"
        case .info:
            "Info & Above"
        case .warnings:
            "Warnings & Errors"
        case .errors:
            "Errors"
        }
    }

    func includes(_ event: LogEvent) -> Bool {
        switch self {
        case .all:
            true
        case .info:
            event.inferredSeverity.map {
                $0.rawValue >= ServerLogSeverity.info.rawValue
            } ?? true
        case .warnings:
            event.inferredSeverity.map {
                $0.rawValue >= ServerLogSeverity.warning.rawValue
            } ?? false
        case .errors:
            event.inferredSeverity == .error
        }
    }
}

#Preview {
    LogsView()
        .environment(AppModel())
        .frame(width: 900, height: 600)
}
