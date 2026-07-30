import AppKit
import LlamadockCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale

    var body: some View {
        LlamaDockPage {
            LlamaDockPageHeader(
                "Downloads",
                subtitle: "Hugging Face download queue and imported models"
            ) {
                Button("Browse Models", systemImage: "magnifyingglass") {
                    appModel.selectedSection = .models
                }
            }

            if let error = appModel.modelDownloadError {
                InlineNotice(
                    localizedDownloadError(error, locale: locale),
                    tone: .failed
                )
            }

            if appModel.modelDownloadSnapshot.jobs.isEmpty {
                EmptyStateAction(
                    title: "No Downloads",
                    description:
                        "Browse Hugging Face models, choose a complete GGUF artifact, and add it to this queue.",
                    systemImage: "arrow.down.circle",
                    actionTitle: "Browse Hugging Face"
                ) {
                    appModel.selectedSection = .models
                }
            } else {
                queueSummary

                VStack(spacing: 12) {
                    ForEach(
                        appModel.modelDownloadSnapshot.jobs.reversed()
                    ) { job in
                        DownloadJobCard(
                            job: job,
                            isActive:
                                appModel.modelDownloadSnapshot
                                .activeJobID == job.id,
                            pause: {
                                Task {
                                    await appModel.pauseModelDownload(
                                        id: job.id
                                    )
                                }
                            },
                            resume: {
                                Task {
                                    await appModel.resumeModelDownload(
                                        id: job.id
                                    )
                                }
                            },
                            cancel: {
                                Task {
                                    await appModel.cancelModelDownload(
                                        id: job.id
                                    )
                                }
                            },
                            reveal: {
                                reveal(job)
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle("Downloads")
    }

    private var queueSummary: some View {
        SectionCard {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Queue")
                        .font(.headline)
                    Text(queueDescription)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if totalExpectedBytes > 0 {
                    VStack(alignment: .trailing, spacing: 5) {
                        ProgressView(value: totalProgress)
                            .frame(width: 180)
                        Text(
                            "\(formattedBytes(totalReceivedBytes)) of \(formattedBytes(totalExpectedBytes))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Total download progress")
                    .accessibilityValue(
                        "\(Int(totalProgress * 100)) percent"
                    )
                }
            }
        }
    }

    private var queueDescription: String {
        let jobs = appModel.modelDownloadSnapshot.jobs
        let active = jobs.filter {
            !$0.state.isTerminal && $0.state != .paused
        }.count
        let completed = jobs.filter { $0.state == .completed }.count
        return localized(
            "\(active) active downloads • \(completed) completed"
        )
    }

    private var totalExpectedBytes: Int64 {
        saturatingSum(
            appModel.modelDownloadSnapshot.jobs
                .filter { $0.state != .cancelled }
                .map(\.expectedBytes)
        )
    }

    private var totalReceivedBytes: Int64 {
        saturatingSum(
            appModel.modelDownloadSnapshot.jobs
                .filter { $0.state != .cancelled }
                .map(\.receivedBytes)
        )
    }

    private var totalProgress: Double {
        guard totalExpectedBytes > 0 else {
            return 0
        }
        return min(
            max(
                Double(totalReceivedBytes)
                    / Double(totalExpectedBytes),
                0
            ),
            1
        )
    }

    private func reveal(_ job: ModelDownloadJob) {
        let url = appModel.ownedModelsDirectoryURL
            .appending(
                path: job.destinationRelativeDirectory,
                directoryHint: .isDirectory
            )
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    private func saturatingSum(
        _ values: [Int64]
    ) -> Int64 {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(
                max(value, 0)
            )
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct DownloadJobCard: View {
    @Environment(\.locale) private var locale

    let job: ModelDownloadJob
    let isActive: Bool
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let reveal: () -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.displayName)
                            .font(.headline)
                        Text(job.repositoryID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    StatusBadge(
                        title: job.state.localizedTitle,
                        systemImage: job.state.systemImage,
                        tone: job.state.tone
                    )
                }

                ProgressView(value: job.progress)
                    .accessibilityLabel(
                        "\(job.displayName) download progress"
                    )
                    .accessibilityValue(
                        "\(Int(job.progress * 100)) percent"
                    )

                HStack(spacing: 8) {
                    Text(
                        "\(formattedBytes(job.receivedBytes)) of \(formattedBytes(job.expectedBytes))"
                    )
                    Text("•")
                    Text(
                        "\(job.files.filter(\.isVerified).count) of \(job.files.count) files"
                    )
                    if isActive {
                        Text("•")
                        Text("Active")
                    }

                    Spacer()

                    if canPause {
                        Button("Pause", systemImage: "pause.fill", action: pause)
                    }
                    if canResume {
                        Button(
                            job.state == .failed
                                ? "Retry"
                                : "Resume",
                            systemImage: "play.fill",
                            action: resume
                        )
                        .buttonStyle(.borderedProminent)
                    }
                    if !job.state.isTerminal {
                        Button(
                            "Cancel",
                            systemImage: "xmark",
                            role: .destructive,
                            action: cancel
                        )
                    }
                    if job.state == .completed {
                        Button(
                            "Show in Finder",
                            systemImage: "folder",
                            action: reveal
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let error = job.error {
                    InlineNotice(
                        localizedDownloadError(error, locale: locale),
                        tone: .failed
                    )
                }
            }
        }
    }

    private var canPause: Bool {
        [.queued, .resolving, .downloading].contains(job.state)
    }

    private var canResume: Bool {
        [.paused, .failed].contains(job.state)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }
}

private func localizedDownloadError(
    _ error: String,
    locale: Locale
) -> String {
    switch error {
    case "The imported artifact directory is incomplete. LlamaDock will not overwrite it.":
        appLocalizedString(
            "The imported artifact directory is incomplete. LlamaDock will not overwrite it.",
            locale: locale
        )
    default:
        error
    }
}

private extension ModelDownloadState {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .queued:
            "Queued"
        case .resolving:
            "Resolving"
        case .downloading:
            "Downloading"
        case .paused:
            "Paused"
        case .verifying:
            "Verifying"
        case .importing:
            "Importing"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .queued:
            "clock"
        case .resolving:
            "link"
        case .downloading:
            "arrow.down.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .verifying:
            "checkmark.shield"
        case .importing:
            "square.and.arrow.down"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .cancelled:
            "nosign"
        }
    }

    var tone: LlamaDockStatusTone {
        switch self {
        case .completed:
            .ready
        case .queued,
            .resolving,
            .downloading,
            .verifying,
            .importing:
            .active
        case .paused:
            .degraded
        case .failed:
            .failed
        case .cancelled:
            .stopped
        }
    }
}

#Preview {
    DownloadsView()
        .environment(AppModel())
        .frame(width: 900, height: 650)
}
