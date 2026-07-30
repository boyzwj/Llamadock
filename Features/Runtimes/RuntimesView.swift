import AppKit
import LlamadockCore
import SwiftUI

struct RuntimesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @State private var pendingRuntimeRemoval:
        ManagedRuntimeRecord?

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Runtime")
                        .font(.largeTitle.bold())
                    Text(
                        "Install, activate, update, and roll back llama.cpp"
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, LlamaDockLayout.pagePadding)
            .padding(.vertical, 14)

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
                        if let activeReport {
                            Section("Current Active") {
                                runtimeRow(activeReport)
                            }
                        }

                        Section("Installed and Discovered") {
                            ForEach(
                                inactiveReports,
                                id: \.candidate.id
                            ) { report in
                                runtimeRow(report)
                            }
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
        .confirmationDialog(
            "Delete Managed Runtime?",
            isPresented: Binding(
                get: { pendingRuntimeRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRuntimeRemoval = nil
                    }
                }
            ),
            presenting: pendingRuntimeRemoval
        ) { runtime in
            Button(
                "Delete \(runtime.tag)",
                role: .destructive
            ) {
                pendingRuntimeRemoval = nil
                Task {
                    await appModel.removeManagedRuntime(
                        id: runtime.id
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRuntimeRemoval = nil
            }
        } message: { runtime in
            Text(
                """
                This permanently removes \(runtime.tag) from LlamaDock's \
                managed runtime directory. The active and previous runtimes \
                are always retained for service continuity and rollback.
                """
            )
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

                if appModel.isCheckingRuntimeUpdates
                    || appModel
                        .isManagedRuntimeOperationInProgress
                {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            "Runtime operation in progress"
                        )
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
                        || appModel
                            .isManagedRuntimeOperationInProgress
                )

                Button(
                    appModel.isLatestManagedRuntimeInstalled
                        ? localized("Latest Installed")
                        : localized("Install & Activate")
                ) {
                    Task {
                        await appModel.installLatestRuntime()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appModel.canChangeManagedRuntime
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
                        || !appModel.canChangeManagedRuntime
                )

                Button(
                    "Delete Selected",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    pendingRuntimeRemoval =
                        appModel.selectedManagedRuntimeRecord
                }
                .disabled(
                    !appModel.canRemoveSelectedManagedRuntime
                )
                .help(
                    appModel
                        .selectedManagedRuntimeRemovalBlockReason
                        ?? localized(
                            "Permanently delete this inactive managed runtime."
                        )
                )

                Spacer()
            }
        }
        .padding(16)
        .background(.background.secondary)
    }

    private var activeReport: RuntimeProbeReport? {
        guard
            let activeID =
                appModel.managedRuntimeSnapshot.activeRuntimeID
        else {
            return nil
        }
        return appModel.runtimeReports.first {
            $0.candidate.id == activeID
        }
    }

    private var inactiveReports: [RuntimeProbeReport] {
        guard let activeReport else {
            return appModel.runtimeReports
        }
        return appModel.runtimeReports.filter {
            $0.candidate.id != activeReport.candidate.id
        }
    }

    private func runtimeRow(
        _ report: RuntimeProbeReport
    ) -> some View {
        let releaseTag = appModel.runtimeReleaseTagByRuntimeID[
            report.candidate.id
        ]
        return RuntimeReportRow(
            report: report,
            isActive:
                appModel.managedRuntimeSnapshot.activeRuntimeID
                    == report.candidate.id,
            isPrevious:
                appModel.managedRuntimeSnapshot.previousRuntimeID
                    == report.candidate.id,
            releaseDetails: releaseTag.flatMap {
                appModel.runtimeReleaseDetailsByTag[$0]
            },
            isLoadingReleaseDetails: releaseTag.map {
                appModel.runtimeReleaseDetailsLoadingTags
                    .contains($0)
            } ?? false,
            releaseDetailsError: releaseTag.flatMap {
                appModel.runtimeReleaseDetailsErrorsByTag[$0]
            }
        )
        .tag(report.candidate.id)
        .contextMenu {
            if
                let record =
                    appModel.managedRuntimeSnapshot
                    .installations
                    .first(
                        where: {
                            $0.id == report.candidate.id
                        }
                    )
            {
                Button(
                    "Delete \(record.tag)",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    appModel.selectRuntime(record.id)
                    pendingRuntimeRemoval = record
                }
                .disabled(
                    appModel.managedRuntimeSnapshot.activeRuntimeID
                        == record.id
                        || appModel.managedRuntimeSnapshot
                            .previousRuntimeID == record.id
                        || !appModel.canChangeManagedRuntime
                )
            }
        }
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
                ? localized("No managed runtime installed")
                : localized(
                    "\(snapshot.installations.count) managed runtimes installed, none active"
                )
        }

        if
            let previousID = snapshot.previousRuntimeID,
            let previous = snapshot.installations.first(
                where: { $0.id == previousID }
            )
        {
            return localized(
                "Active \(active.tag) · Previous \(previous.tag) · \(snapshot.installations.count) managed runtimes installed"
            )
        }
        return localized(
            "Active \(active.tag) · \(snapshot.installations.count) managed runtimes installed"
        )
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
            localized("Ready to install")
        case .fetchingRelease:
            localized("Fetching the latest official release…")
        case .downloading(let tag):
            localized("Downloading \(tag)…")
        case .verifyingArchive:
            localized("Verifying archive size and checksum…")
        case .extracting:
            localized("Safely extracting the archive…")
        case .validatingBinaries:
            localized("Validating architecture and binaries…")
        case .registering:
            localized("Registering the managed runtime…")
        case .activating:
            localized("Activating the managed runtime…")
        case .ready(let record):
            localized("\(record.tag) installed and ready")
        case .failed(let stage, let reason):
            localized("Failed during \(stage.rawValue): \(reason)")
        }
    }

    private func latestSourceTitle(
        _ source: RuntimeReleaseCheckSource
    ) -> String {
        switch source {
        case .network:
            localized("from GitHub")
        case .notModifiedCache:
            localized("validated cache")
        case .staleCache:
            localized("offline cache")
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
        panel.title = localized("Choose llama-server or llama")
        panel.message = localized("""
            LlamaDock will inspect this executable but never overwrite it.
            """)
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

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct RuntimeReportRow: View {
    let report: RuntimeProbeReport
    let isActive: Bool
    let isPrevious: Bool
    let releaseDetails: RuntimeReleaseDetails?
    let isLoadingReleaseDetails: Bool
    let releaseDetailsError: String?
    @Environment(\.locale) private var locale
    @State private var isChangelogExpanded = false

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
                    ?? appLocalizedString(
                        "llama-server executable missing",
                        locale: locale
                    )
            )
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            if let capabilities = report.capabilities {
                Text(
                    capabilities.detection == .detected
                        ? appLocalizedString(
                            "\(capabilities.supportedFlags.count) flags detected",
                            locale: locale
                        )
                        : appLocalizedString(
                            "Capabilities unknown",
                            locale: locale
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            releaseDetailsView

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
    private var releaseDetailsView: some View {
        if let releaseDetails {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(
                        "Published",
                        systemImage: "calendar"
                    )
                    Text(
                        releaseDetails.publishedAt,
                        format: .dateTime
                            .year()
                            .month()
                            .day()
                            .hour()
                            .minute()
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    isChangelogExpanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(
                            systemName: isChangelogExpanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(.caption2.bold())
                        Text("Changelog")
                            .font(.caption.bold())
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isChangelogExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            releaseDetails.changelog
                                ?? appLocalizedString(
                                    "No changelog was provided for this release.",
                                    locale: locale
                                )
                        )
                        .font(.caption)
                        .textSelection(.enabled)

                        Link(
                            "View on GitHub",
                            destination:
                                releaseDetails.releasePageURL
                        )
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            }
        } else if isLoadingReleaseDetails {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading release details…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let releaseDetailsError {
            Label(
                "Release details unavailable",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .help(releaseDetailsError)
        }
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
            appLocalizedString("Managed", locale: locale)
        case .officialInstaller:
            appLocalizedString("Official Installer", locale: locale)
        case .homebrew:
            "Homebrew"
        case .custom:
            appLocalizedString("Custom", locale: locale)
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
