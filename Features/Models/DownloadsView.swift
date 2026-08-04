import AppKit
import LlamadockCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @State private var isShowingQueue = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, LlamaDockLayout.pagePadding)
                .padding(.vertical, 14)

            Divider()

            downloadActivity
                .padding(.horizontal, LlamaDockLayout.pagePadding)
                .padding(.vertical, 12)

            Divider()

            ModelHubModelsView(source: appModel.activeModelHubSource)
                .id(appModel.activeModelHubSource)
        }
        .navigationTitle("Downloads")
        .sheet(isPresented: $isShowingQueue) {
            ModelDownloadQueueView {
                isShowingQueue = false
            }
            .frame(minWidth: 760, minHeight: 560)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Downloads")
                    .font(.largeTitle.bold())
                Text("Browse, download, and track GGUF models")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Picker(
                "Model Source",
                selection: Binding(
                    get: { appModel.activeModelHubSource },
                    set: { appModel.activateModelHub($0) }
                )
            ) {
                ForEach(ModelHubSource.allCases, id: \.self) { source in
                    Text(source.localizedTitle(locale: locale))
                        .tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            .disabled(
                appModel.isSearchingHuggingFace
                    || appModel.isLoadingHuggingFaceRepository
            )
        }
    }

    private var downloadActivity: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(
                    activeJobs.isEmpty ? Color.secondary : Color.accentColor
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Active Downloads")
                    .font(.headline)
                Text(activityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if activeExpectedBytes > 0 {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: activeProgress)
                        .frame(width: 170)
                    Text(
                        "\(formattedBytes(activeReceivedBytes)) of \(formattedBytes(activeExpectedBytes))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total download progress")
                .accessibilityValue(
                    "\(Int(activeProgress * 100)) percent"
                )
            }

            Button("Open Download Queue", systemImage: "list.bullet") {
                isShowingQueue = true
            }
            .disabled(appModel.modelDownloadSnapshot.jobs.isEmpty)
        }
    }

    private var activeJobs: [ModelDownloadJob] {
        appModel.modelDownloadSnapshot.jobs.filter {
            !$0.state.isTerminal
        }
    }

    private var activityDescription: String {
        let total = appModel.modelDownloadSnapshot.jobs.count
        guard total > 0 else {
            return localized("No active tasks")
        }
        return localized(
            "\(activeJobs.count) active downloads • \(total) total"
        )
    }

    private var activeExpectedBytes: Int64 {
        saturatingSum(activeJobs.map(\.expectedBytes))
    }

    private var activeReceivedBytes: Int64 {
        saturatingSum(activeJobs.map(\.receivedBytes))
    }

    private var activeProgress: Double {
        guard activeExpectedBytes > 0 else {
            return 0
        }
        return min(
            max(
                Double(activeReceivedBytes) / Double(activeExpectedBytes),
                0
            ),
            1
        )
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    private func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(max(value, 0))
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct ModelDownloadQueueView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale

    let close: () -> Void

    var body: some View {
        LlamaDockPage {
            LlamaDockPageHeader(
                "Download Queue",
                subtitle:
                    "Hugging Face and ModelScope download queue"
            ) {
                Button("Close", systemImage: "xmark", action: close)
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
                        "Browse an online model source, choose a complete GGUF artifact, and add it to this queue.",
                    systemImage: "arrow.down.circle",
                    actionTitle: "Close",
                    action: close
                )
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
                            cleanup: {
                                Task {
                                    await appModel
                                        .discardModelDownload(
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
    @State private var isShowingCleanupConfirmation = false

    let job: ModelDownloadJob
    let isActive: Bool
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let cleanup: () -> Void
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
                        Label(
                            job.source.localizedTitle(
                                locale: locale
                            ),
                            systemImage: job.source.systemImage
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    if
                        [.failed, .cancelled].contains(job.state),
                        !isActive
                    {
                        Button(
                            "Clean Up",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            isShowingCleanupConfirmation = true
                        }
                        .help(
                            "Delete unfinished files and remove this download task."
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
        .alert(
            "Clean Up Download Remnants?",
            isPresented: $isShowingCleanupConfirmation
        ) {
            Button("Clean Up", role: .destructive, action: cleanup)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes unfinished files for \(job.displayName) and removes the task from the download queue. This cannot be undone."
            )
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

private extension ModelHubSource {
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .huggingFace:
            appLocalizedString("Hugging Face", locale: locale)
        case .modelScope:
            appLocalizedString("ModelScope", locale: locale)
        }
    }

    var systemImage: String {
        switch self {
        case .huggingFace:
            "globe"
        case .modelScope:
            "network"
        }
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
