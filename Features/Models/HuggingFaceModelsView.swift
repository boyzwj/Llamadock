import LlamadockCore
import SwiftUI

struct HuggingFaceModelsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if
                appModel.huggingFaceRepositories.isEmpty,
                !appModel.isSearchingHuggingFace
            {
                initialState
            } else {
                HSplitView {
                    repositoryList
                        .frame(minWidth: 300, idealWidth: 360)
                    repositoryDetail
                        .frame(minWidth: 500)
                }
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField(
                    "Model name, owner/repository, URL, or llama -hf command",
                    text: $query
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)

                Button("Search", systemImage: "magnifyingglass") {
                    search()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    query.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        || appModel.isSearchingHuggingFace
                )

                if appModel.isSearchingHuggingFace {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            "Searching Hugging Face"
                        )
                }
            }

            Text(
                "Examples: Qwen GGUF, bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M, or a huggingface.co repository URL."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = appModel.huggingFaceError {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }

            if let error = appModel.modelDownloadError {
                Label(
                    error,
                    systemImage: "arrow.down.circle.dotted"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }
        }
        .padding(14)
    }

    private var initialState: some View {
        ContentUnavailableView {
            Label("Browse GGUF Repositories", systemImage: "globe")
        } description: {
            Text(
                "Search the Hugging Face Hub or paste the same repository reference accepted by llama.cpp's -hf option."
            )
        } actions: {
            Button("Try a Small Test Repository") {
                query = "stories15M GGUF"
                search()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    "\(appModel.huggingFaceRepositories.count) repositories"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(
                appModel.huggingFaceRepositories,
                selection: Binding(
                    get: {
                        appModel.selectedHuggingFaceRepositoryID
                    },
                    set: { id in
                        guard
                            id != appModel
                                .selectedHuggingFaceRepositoryID
                        else {
                            return
                        }
                        Task {
                            await appModel
                                .selectHuggingFaceRepository(id)
                        }
                    }
                )
            ) { repository in
                HuggingFaceRepositoryRow(
                    repository: repository
                )
                .tag(repository.id)
            }
            .listStyle(.sidebar)
            .disabled(
                appModel.isSearchingHuggingFace
                    || appModel.isLoadingHuggingFaceRepository
            )
        }
    }

    @ViewBuilder
    private var repositoryDetail: some View {
        if
            appModel.isLoadingHuggingFaceRepository,
            appModel.huggingFaceCatalog == nil
        {
            ProgressView("Reading repository file tree…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let repository = appModel.selectedHuggingFaceRepository {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    repositoryHeader(repository)

                    if repository.gated.requiresAuthentication
                        || repository.isPrivate
                    {
                        gatedNotice
                    }

                    if let catalog = appModel.huggingFaceCatalog {
                        artifactCatalog(catalog)
                    }

                    if
                        !appModel.modelDownloadSnapshot.jobs
                            .isEmpty
                    {
                        downloadQueue
                    }
                }
                .padding(22)
            }
        } else {
            ContentUnavailableView(
                "Choose a Repository",
                systemImage: "sidebar.right",
                description: Text(
                    "Select a repository to inspect its GGUF files."
                )
            )
        }
    }

    private func repositoryHeader(
        _ repository: HuggingFaceRepository
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(repository.id)
                        .font(.title2.bold())
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Label(
                            repository.downloads.formatted(),
                            systemImage: "arrow.down.circle"
                        )
                        Label(
                            repository.likes.formatted(),
                            systemImage: "heart"
                        )
                        if let pipelineTag = repository.pipelineTag {
                            Text(pipelineTag)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if repository.gated.requiresAuthentication
                    || repository.isPrivate
                {
                    Label("Restricted", systemImage: "lock.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else {
                    Label("Public", systemImage: "globe")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }

            if let reference = appModel.huggingFaceReference {
                Text("Revision: \(reference.revision)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Link(
                "Open on Hugging Face",
                destination: HuggingFaceHubClient.endpoint.appending(
                    path: repository.id
                )
            )
            .font(.caption)
        }
    }

    private var gatedNotice: some View {
        Label {
            Text(
                appModel.isHuggingFaceTokenConfigured
                    ? "A Keychain token was used for this Hub request. Repository access still depends on the token owner's accepted terms and permissions."
                    : "This repository requires a Hugging Face token with access. Add one in Settings; LlamaDock has not sent any credentials."
            )
        } icon: {
            Image(systemName: "lock.trianglebadge.exclamationmark")
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func artifactCatalog(
        _ catalog: HuggingFaceRepositoryCatalog
    ) -> some View {
        let mainArtifacts = catalog.artifacts.filter {
            $0.role == .main
        }
        let companionArtifacts = catalog.artifacts.filter {
            $0.role != .main
        }

        if mainArtifacts.isEmpty {
            ContentUnavailableView(
                "No Main GGUF Artifacts",
                systemImage: "doc.questionmark",
                description: Text(
                    "The repository file tree did not contain a safe main .gguf artifact."
                )
            )
            .frame(minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("GGUF Artifacts")
                    .font(.headline)

                ForEach(mainArtifacts) { artifact in
                    Button {
                        appModel.selectHuggingFaceArtifact(
                            artifact.id
                        )
                    } label: {
                        artifactRow(artifact)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !companionArtifacts.isEmpty {
                companionPicker(companionArtifacts)
            }

            if
                let artifact = appModel
                    .selectedHuggingFaceArtifact
            {
                artifactManifest(
                    appModel.selectedHuggingFaceDownloadArtifacts,
                    primary: artifact
                )
            }

            if !catalog.ignoredPaths.isEmpty {
                Text(
                    "\(catalog.ignoredPaths.count) non-GGUF or unsafe paths were excluded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func companionPicker(
        _ artifacts: [HuggingFaceGGUFArtifact]
    ) -> some View {
        GroupBox("Optional Companions") {
            VStack(alignment: .leading, spacing: 9) {
                Text(
                    "Choose at most one vision projector and one draft model. Selected companions share the main model's download, verification, import, and Profile transaction."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(artifacts) { artifact in
                    Toggle(
                        isOn: Binding(
                            get: {
                                appModel
                                    .selectedHuggingFaceCompanionArtifactIDs
                                    .contains(artifact.id)
                            },
                            set: { selected in
                                appModel
                                    .setHuggingFaceCompanionArtifact(
                                        artifact.id,
                                        selected: selected
                                    )
                            }
                        )
                    ) {
                        HStack {
                            Label(
                                artifact.displayName,
                                systemImage: artifact.role.icon
                            )
                            Spacer()
                            Text(byteCount(artifact.totalSize))
                                .foregroundStyle(.secondary)
                            if let quantization = artifact.quantization {
                                Text(quantization)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!artifact.isComplete)
                    .help(
                        artifact.isComplete
                            ? "Include this companion in the atomic download and generated Profile."
                            : "This split companion is incomplete and cannot be selected."
                    )
                }
            }
            .padding(.top, 4)
        }
    }

    private func artifactRow(
        _ artifact: HuggingFaceGGUFArtifact
    ) -> some View {
        let isSelected = artifact.id
            == appModel.selectedHuggingFaceArtifactID

        return HStack(spacing: 12) {
            Image(systemName: artifact.role.icon)
                .foregroundStyle(
                    artifact.isComplete ? Color.accentColor : .orange
                )
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(artifact.role.title)
                    if let quantization = artifact.quantization {
                        Text("•")
                        Text(quantization)
                    }
                    Text("•")
                    Text(byteCount(artifact.totalSize))
                    if artifact.files.count > 1 {
                        Text("•")
                        Text("\(artifact.files.count) parts")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                artifact.isComplete ? "Complete" : "Incomplete",
                systemImage: artifact.isComplete
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(
                artifact.isComplete ? .green : .orange
            )
        }
        .padding(10)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.55)
                        : Color.clear,
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
    }

    private func artifactManifest(
        _ artifacts: [HuggingFaceGGUFArtifact],
        primary: HuggingFaceGGUFArtifact
    ) -> some View {
        GroupBox("Selected Artifact Manifest") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(
                                artifact.role.title,
                                systemImage: artifact.role.icon
                            )
                            .font(.caption.bold())
                            Text(artifact.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(artifact.files) { file in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(file.repositoryFile.path)
                                        .font(
                                            .system(
                                                .caption,
                                                design: .monospaced
                                            )
                                        )
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(
                                        byteCount(
                                            file.repositoryFile.size
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                if
                                    let sha256 = file.repositoryFile
                                        .expectedSHA256
                                {
                                    Text("SHA-256 \(sha256)")
                                        .font(
                                            .system(
                                                .caption2,
                                                design: .monospaced
                                            )
                                        )
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                } else {
                                    Text(
                                        "No SHA-256 digest declared by the Hub."
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    if artifact.id != artifacts.last?.id {
                        Divider()
                    }
                }

                Label(
                    artifacts.allSatisfy(
                        \.expectedSHA256Coverage
                    )
                        ? "Every file declares a Hub LFS SHA-256 digest; all files also receive bounded GGUF structure validation."
                        : "Files without a Hub SHA-256 digest still receive exact-size and bounded GGUF structure validation before import.",
                    systemImage: artifacts.allSatisfy(
                        \.expectedSHA256Coverage
                    )
                        ? "checkmark.shield"
                        : "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                downloadAction(for: primary)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func downloadAction(
        for artifact: HuggingFaceGGUFArtifact
    ) -> some View {
        if
            let job = appModel
                .selectedHuggingFaceArtifactDownloadJob
        {
            downloadJobControls(job)
        } else {
            Button(
                appModel.selectedHuggingFaceCompanionArtifacts
                    .isEmpty
                    ? "Download to Local Library"
                    : "Download Model and Companions",
                systemImage: "arrow.down.circle"
            ) {
                Task {
                    await appModel
                        .downloadSelectedHuggingFaceArtifact()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                artifact.role != .main
                    || !artifact.isComplete
                    || (
                        (
                            appModel
                                .selectedHuggingFaceRepository?
                                .gated.requiresAuthentication
                                == true
                                || appModel
                                    .selectedHuggingFaceRepository?
                                    .isPrivate
                                    == true
                        )
                            && !appModel
                                .isHuggingFaceTokenConfigured
                    )
            )
            .help(
                artifact.role == .main
                    ? "Download, verify, and import this artifact without overwriting existing files."
                    : "Choose a main artifact. Companion selection is managed with its main model."
            )
        }
    }

    private var downloadQueue: some View {
        GroupBox("Download Queue") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(
                    appModel.modelDownloadSnapshot.jobs.reversed()
                ) { job in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.displayName)
                                    .font(.subheadline.bold())
                                Text(job.repositoryID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.state.title)
                                .font(.caption.bold())
                                .foregroundStyle(
                                    job.state.tint
                                )
                        }

                        downloadJobControls(job)
                    }
                    .padding(10)
                    .background(
                        Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
            .padding(.top, 4)
        }
    }

    private func downloadJobControls(
        _ job: ModelDownloadJob
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: job.progress) {
                Text(
                    "\(byteCount(job.receivedBytes)) of \(byteCount(job.expectedBytes))"
                )
                .font(.caption)
            }
            .accessibilityLabel(
                "\(job.displayName) download progress"
            )
            .accessibilityValue(
                downloadProgressAccessibilityValue(job)
            )

            if let error = job.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                if [
                    ModelDownloadState.queued,
                    .resolving,
                    .downloading,
                ].contains(job.state) {
                    Button("Pause", systemImage: "pause.fill") {
                        Task {
                            await appModel.pauseModelDownload(
                                id: job.id
                            )
                        }
                    }
                }

                if [.paused, .failed].contains(job.state) {
                    Button("Resume", systemImage: "play.fill") {
                        Task {
                            await appModel.resumeModelDownload(
                                id: job.id
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !job.state.isTerminal {
                    Button(
                        "Cancel",
                        systemImage: "xmark",
                        role: .destructive
                    ) {
                        Task {
                            await appModel.cancelModelDownload(
                                id: job.id
                            )
                        }
                    }
                }

                if job.state == .completed {
                    Label(
                        "Imported into Local Library",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
            }
        }
    }

    private func search() {
        Task {
            await appModel.searchHuggingFace(query)
        }
    }

    private func byteCount(
        _ value: Int64
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: value,
            countStyle: .file
        )
    }

    private func downloadProgressAccessibilityValue(
        _ job: ModelDownloadJob
    ) -> String {
        let progress = min(max(job.progress, 0), 1)
        let percentage = Int(
            (progress * 100).rounded()
        )
        return "\(percentage) percent, \(job.state.title)"
    }
}

private struct HuggingFaceRepositoryRow: View {
    let repository: HuggingFaceRepository

    var body: some View {
        HStack(spacing: 10) {
            Image(
                systemName: repository.gated.requiresAuthentication
                    || repository.isPrivate
                    ? "lock.fill"
                    : "shippingbox"
            )
            .foregroundStyle(
                repository.gated.requiresAuthentication
                    || repository.isPrivate
                    ? .orange
                    : Color.accentColor
            )
            .frame(width: 20)
            .accessibilityLabel(
                repository.gated.requiresAuthentication
                    || repository.isPrivate
                    ? "Restricted repository"
                    : "Public repository"
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(repository.id)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Label(
                        repository.downloads.formatted(),
                        systemImage: "arrow.down"
                    )
                    Label(
                        repository.likes.formatted(),
                        systemImage: "heart"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension HuggingFaceGGUFRole {
    var title: String {
        switch self {
        case .main:
            "Main"
        case .mmproj:
            "Vision Projector"
        case .draft:
            "Draft"
        }
    }

    var icon: String {
        switch self {
        case .main:
            "brain"
        case .mmproj:
            "eye"
        case .draft:
            "hare"
        }
    }
}

private extension HuggingFaceGGUFArtifact {
    var expectedSHA256Coverage: Bool {
        files.allSatisfy {
            $0.repositoryFile.expectedSHA256 != nil
        }
    }
}

private extension ModelDownloadState {
    var title: String {
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

    var tint: Color {
        switch self {
        case .completed:
            .green
        case .failed:
            .red
        case .paused, .cancelled:
            .orange
        case
            .queued,
            .resolving,
            .downloading,
            .verifying,
            .importing:
            .accentColor
        }
    }
}

#Preview {
    HuggingFaceModelsView()
        .environment(AppModel())
        .frame(width: 980, height: 720)
}
