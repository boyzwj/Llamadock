import LlamadockCore
import SwiftUI

struct ModelHubModelsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @State private var query = ""

    let source: ModelHubSource

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if
                appModel.huggingFaceRepositories.isEmpty,
                appModel.isSearchingHuggingFace
            {
                ProgressView("Loading popular GGUF models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.huggingFaceRepositories.isEmpty {
                initialState
            } else {
                HSplitView {
                    repositoryList
                        .frame(
                            minWidth: ModelBrowserSplitLayout.listMinWidth,
                            idealWidth: ModelBrowserSplitLayout.listIdealWidth,
                            maxWidth: ModelBrowserSplitLayout.listMaxWidth
                        )
                    repositoryDetail
                        .frame(
                            minWidth: ModelBrowserSplitLayout.detailMinWidth,
                            maxWidth: .infinity
                        )
                }
            }
        }
        .onAppear {
            appModel.activateModelHub(source)
            if appModel.huggingFaceRepositories.isEmpty {
                query = "GGUF"
                search()
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized("Add Model from \(sourceTitle)"))
                .font(.headline)

            HStack(spacing: 8) {
                TextField(
                    source == .huggingFace
                        ? "Model name, owner/repository, URL, or llama -hf command"
                        : "Model name, owner/repository, or modelscope.cn URL",
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
                            localized(
                                "Searching \(sourceTitle)"
                            )
                        )
                }
            }

            Text(
                source == .huggingFace
                    ? "Examples: Qwen GGUF, bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M, or a huggingface.co repository URL."
                    : "Examples: Qwen GGUF, unsloth/DeepSeek-R1-GGUF:Q4_K_M, or a modelscope.cn repository URL."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Label(
                localized("Source: \(sourceHost)"),
                systemImage: "network"
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
                source == .huggingFace
                    ? "Search the Hugging Face Hub or paste the same repository reference accepted by llama.cpp's -hf option."
                    : "Search public GGUF repositories on ModelScope or paste a modelscope.cn repository URL."
            )
        } actions: {
            Button("Load Popular GGUF Models") {
                query = "GGUF"
                search()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        query == "GGUF"
                            ? "Suggested Models"
                            : "Search Results"
                    )
                    .font(.headline)
                    Text(
                        "\(appModel.huggingFaceRepositories.count) repositories"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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
                                .selectModelHubRepository(
                                    id,
                                    source: source
                                )
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
                localized("Open on \(sourceTitle)"),
                destination: repositoryURL(repository.id)
            )
            .font(.caption)
        }
    }

    private var gatedNotice: some View {
        Label {
            Text(
                source == .modelScope
                    ? localized(
                        "LlamaDock currently downloads public ModelScope repositories without credentials. Private or gated ModelScope repositories are not yet supported."
                    )
                    : appModel.isHuggingFaceTokenConfigured
                        ? localized(
                            "A Keychain token was used for this Hub request. Repository access still depends on the token owner's accepted terms and permissions."
                        )
                        : localized(
                            "This repository requires a Hugging Face token with access. Add one in Settings; LlamaDock has not sent any credentials."
                        )
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
                            ? localized(
                                "Include this companion in the atomic download and generated Profile."
                            )
                            : localized(
                                "This split companion is incomplete and cannot be selected."
                            )
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
                    Text(artifact.role.localizedTitle(locale: locale))
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
                artifact.isComplete
                    ? localized("Complete")
                    : localized("Incomplete"),
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
                                artifact.role.localizedTitle(locale: locale),
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
                        ? localized(
                            "Every file declares a Hub LFS SHA-256 digest; all files also receive bounded GGUF structure validation."
                        )
                        : localized(
                            "Files without a Hub SHA-256 digest still receive exact-size and bounded GGUF structure validation before import."
                        ),
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
                    ? localized("Download to Local Library")
                    : localized("Download Model and Companions"),
                systemImage: "arrow.down.circle"
            ) {
                Task {
                    await appModel
                        .downloadSelectedModelHubArtifact()
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
                            && (
                                source == .modelScope
                                    || !appModel
                                        .isHuggingFaceTokenConfigured
                            )
                    )
            )
            .help(
                artifact.role == .main
                    ? localized(
                        "Download, verify, and import this artifact without overwriting existing files."
                    )
                    : localized(
                        "Choose a main artifact. Companion selection is managed with its main model."
                    )
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
                            Text(job.state.localizedTitle(locale: locale))
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
            await appModel.searchModelHub(
                query,
                source: source
            )
        }
    }

    private var sourceTitle: String {
        switch source {
        case .huggingFace:
            localized("Hugging Face")
        case .modelScope:
            localized("ModelScope")
        }
    }

    private var sourceHost: String {
        switch source {
        case .huggingFace:
            "huggingface.co"
        case .modelScope:
            "modelscope.cn"
        }
    }

    private var sourceEndpoint: URL {
        switch source {
        case .huggingFace:
            HuggingFaceHubClient.endpoint
        case .modelScope:
            ModelScopeHubClient.endpoint
        }
    }

    private func repositoryURL(
        _ repositoryID: String
    ) -> URL {
        switch source {
        case .huggingFace:
            sourceEndpoint.appending(path: repositoryID)
        case .modelScope:
            sourceEndpoint
                .appending(path: "models")
                .appending(path: repositoryID)
        }
    }

    private func byteCount(
        _ value: Int64
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }

    private func downloadProgressAccessibilityValue(
        _ job: ModelDownloadJob
    ) -> String {
        let progress = min(max(job.progress, 0), 1)
        let percentage = Int(
            (progress * 100).rounded()
        )
        return localized(
            "\(percentage) percent, \(job.state.localizedTitle(locale: locale))"
        )
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct HuggingFaceRepositoryRow: View {
    let repository: HuggingFaceRepository
    @Environment(\.locale) private var locale

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
                    ? Text(
                        appLocalizedString(
                            "Restricted repository",
                            locale: locale
                        )
                    )
                    : Text(
                        appLocalizedString(
                            "Public repository",
                            locale: locale
                        )
                    )
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
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .main:
            appLocalizedString("Main", locale: locale)
        case .mmproj:
            appLocalizedString("Vision Projector", locale: locale)
        case .draft:
            appLocalizedString("Draft", locale: locale)
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
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .queued:
            appLocalizedString("Queued", locale: locale)
        case .resolving:
            appLocalizedString("Resolving", locale: locale)
        case .downloading:
            appLocalizedString("Downloading", locale: locale)
        case .paused:
            appLocalizedString("Paused", locale: locale)
        case .verifying:
            appLocalizedString("Verifying", locale: locale)
        case .importing:
            appLocalizedString("Importing", locale: locale)
        case .completed:
            appLocalizedString("Completed", locale: locale)
        case .failed:
            appLocalizedString("Failed", locale: locale)
        case .cancelled:
            appLocalizedString("Cancelled", locale: locale)
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
    ModelHubModelsView(source: .huggingFace)
        .environment(AppModel())
        .frame(width: 980, height: 720)
}
