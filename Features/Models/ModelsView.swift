import AppKit
import LlamadockCore
import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @State private var searchText = ""
    @State private var validationFilter = ModelValidationFilter.all
    @State private var source = ModelSource.local
    @State private var modelSettingsSearchText = ""
    @State private var profileEditorLevel =
        ProfileEditorLevel.basic
    @State private var pendingModelTrash: LocalModelFile?
    @State private var pendingProfileDeletion: LaunchProfile?
    let mode: ModelPageMode

    init(mode: ModelPageMode = .browser) {
        self.mode = mode
    }

    var body: some View {
        Group {
            switch mode {
            case .browser:
                browserBody
            case .settings:
                modelSettingsBody
            }
        }
        .navigationTitle(
            mode == .browser ? "Models" : "Model Settings"
        )
        .toolbar {
            ToolbarItemGroup {
                if mode == .browser, source == .local {
                    Button("Add Folder", systemImage: "folder.badge.plus") {
                        chooseDirectories()
                    }

                    Button("Open GGUF", systemImage: "doc.badge.plus") {
                        chooseModel()
                    }

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await appModel.refreshModels()
                        }
                    }
                    .disabled(appModel.isRefreshingModels)

                    if let model = appModel.selectedLibraryModel {
                        Button("Reveal in Finder", systemImage: "folder") {
                            reveal(model.url)
                        }

                        Button(
                            "Move to Trash",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            pendingModelTrash = model
                        }
                        .disabled(
                            appModel.localModelTrashBlockReason(
                                model
                            ) != nil
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "Move Model to Trash?",
            isPresented: Binding(
                get: { pendingModelTrash != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingModelTrash = nil
                    }
                }
            ),
            presenting: pendingModelTrash
        ) { model in
            Button(
                "Move \(model.url.lastPathComponent) to Trash",
                role: .destructive
            ) {
                pendingModelTrash = nil
                Task {
                    await appModel.moveLocalModelToTrash(
                        id: model.id
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingModelTrash = nil
            }
        } message: { model in
            Text(trashConfirmationMessage(for: model))
        }
        .confirmationDialog(
            "Delete Model Configuration?",
            isPresented: Binding(
                get: { pendingProfileDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingProfileDeletion = nil
                    }
                }
            ),
            presenting: pendingProfileDeletion
        ) { profile in
            Button(
                "Delete \(profile.name)",
                role: .destructive
            ) {
                pendingProfileDeletion = nil
                appModel.selectProfile(profile.id)
                Task {
                    await appModel.deleteSelectedProfile()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingProfileDeletion = nil
            }
        } message: { profile in
            Text(
                "This removes only the saved configuration for \(profile.name). The GGUF model file is not deleted."
            )
        }
    }

    private var browserBody: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models")
                        .font(.largeTitle.bold())
                    Text(
                        "Local GGUF library, Hugging Face, and ModelScope"
                    )
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Model Source", selection: $source) {
                    ForEach(ModelSource.allCases) { source in
                        Label(
                            source.localizedTitle(locale: locale),
                            systemImage: source.icon
                        )
                            .tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 420)
            }
            .padding(.horizontal, LlamaDockLayout.pagePadding)
            .padding(.vertical, 14)

            Divider()

            switch source {
            case .local:
                localLibrary
            case .huggingFace:
                ModelHubModelsView(source: .huggingFace)
                    .id(ModelHubSource.huggingFace)
            case .modelScope:
                ModelHubModelsView(source: .modelScope)
                    .id(ModelHubSource.modelScope)
            }
        }
    }

    private var modelSettingsBody: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Configured Models")
                            .font(.title2.bold())
                        Text(
                            "\(appModel.enabledRouterProfiles.count) enabled • \(appModel.loadedServerModelCount) loaded"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    addModelConfigurationMenu
                }
                .padding(14)

                Divider()

                if appModel.profiles.isEmpty {
                    EmptyStateAction(
                        title: "No Configured Models",
                        description:
                            "Choose a local GGUF model to make it available through llama-server.",
                        systemImage: "cube.transparent",
                        actionTitle: "Browse Models"
                    ) {
                        appModel.selectedSection = .models
                    }
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField(
                            "Search configured models",
                            text: $modelSettingsSearchText
                        )
                        .textFieldStyle(.plain)

                        if !modelSettingsSearchText.isEmpty {
                            Button("Clear Search", systemImage: "xmark.circle.fill") {
                                modelSettingsSearchText = ""
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)

                    List(
                        filteredSettingsProfiles,
                        selection: Binding(
                            get: { appModel.selectedProfileID },
                            set: { appModel.selectProfile($0) }
                        )
                    ) { profile in
                        ModelSettingRow(
                            profile: profile,
                            runtimeModel: appModel.serverModel(
                                for: profile
                            )
                        )
                        .tag(profile.id)
                    }
                    .listStyle(.sidebar)
                }

                Divider()

                HStack {
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        appModel.duplicateSelectedProfile()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(appModel.profile == nil)
                    .help("Duplicate Configuration")

                    Button(
                        "Delete",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        pendingProfileDeletion = appModel.profile
                    }
                    .labelStyle(.iconOnly)
                    .disabled(appModel.profile == nil)
                    .help("Delete Configuration")

                    Spacer()

                    Menu {
                        Button(
                            "Import…",
                            systemImage: "square.and.arrow.down"
                        ) {
                            importProfile()
                        }
                        Button(
                            "Export…",
                            systemImage: "square.and.arrow.up"
                        ) {
                            exportProfile()
                        }
                        .disabled(appModel.profile == nil)
                    } label: {
                        Label("More Actions", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(12)
            }
            .frame(
                minWidth: 220,
                idealWidth: 250,
                maxWidth: 290
            )

            if appModel.profile == nil {
                ContentUnavailableView(
                    "Choose a Configured Model",
                    systemImage: "cube.transparent",
                    description: Text(
                        "Select a model on the left to review its availability, API name, and performance settings."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        modelConfigurationHeader
                        if appModel.serverSnapshot.run != nil {
                            InlineNotice(
                                "Changes are saved automatically. Restart the server to apply them."
                            )
                        }
                        profileEditor
                    }
                    .padding(18)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
    }

    private var addModelConfigurationMenu: some View {
        Menu {
            let candidates = appModel.localModels.filter {
                $0.validation == .valid && $0.role == .main
            }
            if candidates.isEmpty {
                Text("No validated local models")
            } else {
                ForEach(candidates) { model in
                    Button(model.displayName) {
                        appModel.createProfile(for: model)
                    }
                }
            }

            Divider()

            Button("Browse Model Library…", systemImage: "externaldrive") {
                appModel.selectedSection = .models
            }
        } label: {
            Label("Add Configured Model", systemImage: "plus")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add Configured Model")
    }

    private var localLibrary: some View {
        VStack(spacing: 0) {
            rootsBar
            Divider()

            if
                appModel.isRefreshingModels,
                appModel.modelScanSnapshot == nil
            {
                ProgressView("Scanning GGUF metadata…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.localModels.isEmpty {
                emptyLibrary
            } else {
                HSplitView {
                    modelList
                        .frame(
                            minWidth: ModelBrowserSplitLayout.listMinWidth,
                            idealWidth: ModelBrowserSplitLayout.listIdealWidth,
                            maxWidth: ModelBrowserSplitLayout.listMaxWidth
                        )
                    modelDetail
                        .frame(
                            minWidth: ModelBrowserSplitLayout.detailMinWidth,
                            maxWidth: .infinity
                        )
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search local models"
        )
    }

    private var rootsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Label {
                    Text("LlamaDock Models")
                } icon: {
                    Image(systemName: "internaldrive")
                }
                .help(appModel.ownedModelsDirectoryURL.path)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())

                ForEach(appModel.modelDirectories) { directory in
                    Menu {
                        Button("Reveal in Finder") {
                            reveal(directory.url)
                        }
                        Divider()
                        Button("Remove from Library", role: .destructive) {
                            Task {
                                await appModel.removeModelDirectory(
                                    id: directory.id
                                )
                            }
                        }
                    } label: {
                        Label(
                            directory.record.displayName,
                            systemImage: "folder"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(directory.url.path)
                }

                ForEach(appModel.modelDirectoryIssues) { issue in
                    Label(
                        issue.record.displayName,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .help(issue.reason)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12), in: Capsule())
                }

                Button("Add Folder…", systemImage: "plus") {
                    chooseDirectories()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Local Models", systemImage: "externaldrive")
        } description: {
            Text(
                "Add one or more folders to scan GGUF files without moving them, or open a single GGUF file."
            )
        } actions: {
            HStack {
                Button("Add Model Folder…") {
                    chooseDirectories()
                }
                .buttonStyle(.borderedProminent)

                Button("Open GGUF…") {
                    chooseModel()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    "\(filteredModels.count) of \(appModel.localModels.count) files"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Picker("Validation", selection: $validationFilter) {
                    ForEach(ModelValidationFilter.allCases) { filter in
                        Text(filter.localizedTitle(locale: locale))
                            .tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 120)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(
                filteredModels,
                selection: Binding(
                    get: { appModel.selectedLibraryModelID },
                    set: { appModel.selectLibraryModel($0) }
                )
            ) { model in
                ModelLibraryRow(model: model)
                    .tag(model.id)
                    .contextMenu {
                        if
                            model.validation == .valid,
                            model.role == .main
                        {
                            Button("Open Model Settings") {
                                if appModel.profiles(for: model).isEmpty {
                                    appModel.createProfile(for: model)
                                }
                                appModel.selectedSettingsTab = .models
                                appModel.selectedSection = .settings
                            }
                        }
                        Button("Reveal in Finder") {
                            reveal(model.url)
                        }
                        Button("Copy Path") {
                            copy(model.url.path)
                        }
                        Divider()
                        Button(
                            "Move to Trash",
                            role: .destructive
                        ) {
                            pendingModelTrash = model
                        }
                        .disabled(
                            appModel.localModelTrashBlockReason(
                                model
                            ) != nil
                        )
                    }
            }
            .listStyle(.sidebar)

            if let snapshot = appModel.modelScanSnapshot {
                Divider()
                HStack {
                    Text(byteCount(appModel.localModelByteCount))
                    Text("•")
                    Text(
                        localized(
                            "Scanned \(snapshot.roots.count) model folders"
                        )
                    )
                    if !snapshot.issues.isEmpty {
                        Text("•")
                        Label(
                            "\(snapshot.issues.count) scan issues",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .help(
                            snapshot.issues.map {
                                "\($0.rootURL.path): \($0.reason)"
                            }.joined(separator: "\n")
                        )
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private var modelDetail: some View {
        if let model = appModel.selectedLibraryModel {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelHeader(model)
                    metadataCard(model)
                    modelRuntimeCard(model)
                }
                .padding(22)
            }
        } else {
            ContentUnavailableView(
                "Choose a Model",
                systemImage: "sidebar.right",
                description: Text(
                    "Select a GGUF file to inspect its metadata and current router state."
                )
            )
        }
    }

    private func modelHeader(
        _ model: LocalModelFile
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.displayName)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                    Text(model.url.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                ModelStatusBadge(model: model)
            }

            HStack {
                if
                    model.validation == .valid,
                    model.role == .main
                {
                    Button("Open Model Settings") {
                        if appModel.profiles(for: model).isEmpty {
                            appModel.createProfile(for: model)
                        } else if let first = appModel.profiles(
                            for: model
                        ).first {
                            appModel.selectProfile(first.id)
                        }
                        appModel.selectedSettingsTab = .models
                        appModel.selectedSection = .settings
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Reveal in Finder") {
                    reveal(model.url)
                }
                Button("Copy Path") {
                    copy(model.url.path)
                }
                Button(
                    "Move to Trash",
                    role: .destructive
                ) {
                    pendingModelTrash = model
                }
                .disabled(
                    appModel.localModelTrashBlockReason(
                        model
                    ) != nil
                )
                .help(
                    appModel.localModelTrashBlockReason(
                        model
                    ) ?? localized(
                        "Move this GGUF file to the system Trash."
                    )
                )
            }

            if case .invalid(let reason) = model.validation {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func modelRuntimeCard(
        _ model: LocalModelFile
    ) -> some View {
        let settings = appModel.profiles(for: model)
        let runtimeModels = settings.compactMap {
            appModel.serverModel(for: $0)
        }

        return GroupBox("Router State") {
            VStack(alignment: .leading, spacing: 10) {
                if settings.isEmpty {
                    Label(
                        "This model is not included in the generated llama-server config.",
                        systemImage: "minus.circle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(settings) { setting in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(setting.router.identifier)
                                    .font(.headline)
                                Text(setting.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ServerModelStateBadge(
                                state: appModel.serverModel(
                                    for: setting
                                )?.state,
                                isEnabled: setting.router.isEnabled
                            )
                        }
                    }
                }

                if !runtimeModels.isEmpty {
                    Text(
                        "Status is reported by the running llama-server /models endpoint."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private func metadataCard(
        _ model: LocalModelFile
    ) -> some View {
        GroupBox("GGUF Metadata") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                metadataRow(
                    "Role",
                    model.role.localizedDisplayName(locale: locale)
                )
                metadataRow("File size", byteCount(model.fileSize))

                if let metadata = model.metadata {
                    metadataRow("Architecture", metadata.architecture)
                    metadataRow(
                        "Parameters",
                        parameterCount(metadata.parameterCount)
                    )
                    metadataRow(
                        "Quantization",
                        metadata.quantization
                            ?? metadata.fileType.map(String.init)
                            ?? localized("Unknown")
                    )
                    metadataRow(
                        "Context",
                        metadata.contextLength.map {
                            $0.formatted()
                        } ?? localized("Unknown")
                    )
                    metadataRow(
                        "Tensors",
                        metadata.tensorCount.formatted()
                    )
                    metadataRow(
                        "GGUF",
                        "v\(metadata.formatVersion)"
                    )
                    metadataRow(
                        "Chat template",
                        metadata.hasChatTemplate
                            ? localized("Present")
                            : localized("Not declared")
                    )
                    if let shard = metadata.shard {
                        metadataRow(
                            "Split",
                            localized(
                                "Shard \(shard.zeroBasedIndex + 1) of \(shard.count)"
                            )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private func metadataRow(
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

    private func profilesCard(
        _ model: LocalModelFile
    ) -> some View {
        let modelProfiles = appModel.profiles(for: model)

        return GroupBox("Profiles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(
                        "Profile",
                        selection: Binding(
                            get: {
                                modelProfiles.contains(
                                    where: {
                                        $0.id == appModel.selectedProfileID
                                    }
                                )
                                    ? appModel.selectedProfileID
                                    : nil
                            },
                            set: { appModel.selectProfile($0) }
                        )
                    ) {
                        Text("Choose a profile")
                            .tag(nil as UUID?)
                        ForEach(modelProfiles) { profile in
                            Text(profile.name)
                                .tag(Optional(profile.id))
                        }
                    }
                    .disabled(modelProfiles.isEmpty)

                    Button("New", systemImage: "plus") {
                        appModel.createProfile(for: model)
                    }

                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        appModel.duplicateSelectedProfile()
                    }
                    .disabled(
                        !modelProfiles.contains(
                            where: {
                                $0.id == appModel.selectedProfileID
                            }
                        )
                    )

                    Button(
                        "Delete",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        Task {
                            await appModel.deleteSelectedProfile()
                        }
                    }
                    .disabled(
                        !modelProfiles.contains(
                            where: {
                                $0.id == appModel.selectedProfileID
                            }
                        )
                    )

                    Menu {
                        Button("Import Profile…", systemImage: "square.and.arrow.down") {
                            importProfile()
                        }
                        Button("Export Selected Profile…", systemImage: "square.and.arrow.up") {
                            exportProfile()
                        }
                        .disabled(
                            !modelProfiles.contains(
                                where: {
                                    $0.id == appModel.selectedProfileID
                                }
                            )
                        )
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if modelProfiles.isEmpty {
                    Text(
                        "Create a profile to configure and launch this model."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        localized(
                            "\(modelProfiles.count) saved profiles. The most recently edited profile appears first."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var modelConfigurationHeader: some View {
        if let profile = appModel.profile {
            SectionCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "cube.transparent.fill")
                            .font(.title2)
                            .foregroundStyle(
                                profile.router.isEnabled
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .frame(width: 42, height: 42)
                            .background(
                                Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.title2.bold())
                                .lineLimit(2)
                            Text(
                                URL(filePath: profile.model.mainPath)
                                    .lastPathComponent
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(profile.model.mainPath)
                        }

                        Spacer(minLength: 8)

                        ServerModelStateBadge(
                            state: appModel.serverModel(for: profile)?.state,
                            isEnabled: profile.router.isEnabled
                        )
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Availability")
                                .font(.headline)
                            Text(
                                "Choose whether this model is hidden, loaded when requested, or kept ready from startup."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Picker(
                            "Model Availability",
                            selection: modelAvailabilityBinding
                        ) {
                            ForEach(ModelAvailabilityChoice.allCases) {
                                Label($0.title, systemImage: $0.systemImage)
                                    .tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    Label(
                        "Saved automatically",
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Picker(
                    "Configuration Detail",
                    selection: $profileEditorLevel
                ) {
                    ForEach(ProfileEditorLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Configuration detail level")

                Text(profileEditorLevel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            capabilitySummary
            identitySettingsCard
            commonPerformanceCard

            if profileEditorLevel.includes(.performance) {
                performanceTuningCard
            }

            if profileEditorLevel.includes(.advanced) {
                companionModelsCard
                samplingSettingsCard
                systemPromptCard
                extraArgumentsCard
                generatedConfigurationCard
            }
        }
    }

    private var identitySettingsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionHeader(
                    "Names and File",
                    subtitle:
                        "Use a friendly name in LlamaDock and a stable identifier in API requests."
                )

                configurationField(
                    "Display Name",
                    detail:
                        "Shown only in LlamaDock. Rename it to distinguish configurations for the same model."
                ) {
                    TextField("Display Name", text: profileNameBinding)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                configurationField(
                    "API Model Identifier",
                    detail:
                        "Clients send this value as the model name. Keep it short, unique, and stable."
                ) {
                    TextField("model-id", text: routerIdentifierBinding)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                configurationField(
                    "Model File",
                    detail:
                        "The GGUF file used by this configuration.",
                    flag: "--model"
                ) {
                    HStack(spacing: 8) {
                        Text(appModel.profile?.model.mainPath ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer(minLength: 4)

                        Button("Reveal in Finder", systemImage: "folder") {
                            if let path = appModel.profile?.model.mainPath {
                                reveal(URL(filePath: path))
                            }
                        }
                        .labelStyle(.iconOnly)
                        .help("Reveal in Finder")

                        Button("Copy Path", systemImage: "doc.on.doc") {
                            copy(appModel.profile?.model.mainPath ?? "")
                        }
                        .labelStyle(.iconOnly)
                        .help("Copy Path")
                    }
                }
            }
        }
    }

    private var commonPerformanceCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    settingsSectionHeader(
                        "Everyday Performance",
                        subtitle:
                            "Leave fields empty to inherit the global model defaults."
                    )

                    Spacer(minLength: 12)

                    if hasCustomEverydayPerformanceSettings {
                        Button("Use Global Defaults") {
                            resetEverydayPerformanceSettings()
                        }
                        .controlSize(.small)
                    }
                }

                configurationField(
                    "Context Size",
                    detail:
                        "Maximum tokens the model can consider at once. Larger contexts use more memory.",
                    flag: "--ctx-size"
                ) {
                    TextField(
                        "Global default",
                        text: contextSizeBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                }

                Divider()

                configurationField(
                    "GPU Layers",
                    detail:
                        "Number of model layers offloaded to the GPU. Leave empty unless you need manual control.",
                    flag: "--n-gpu-layers"
                ) {
                    TextField(
                        "Global default",
                        text: gpuLayersBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private var performanceTuningCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    settingsSectionHeader(
                        "Performance Tuning",
                        subtitle:
                            "Optional per-model overrides for the global performance defaults."
                    )

                    Spacer(minLength: 12)

                    if hasCustomPerformanceTuningSettings {
                        Button("Use Global Defaults") {
                            resetPerformanceTuningSettings()
                        }
                        .controlSize(.small)
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 230),
                            alignment: .topLeading
                        )
                    ],
                    alignment: .leading,
                    spacing: 16
                ) {
                    compactValueField(
                        "Threads",
                        detail: "CPU worker threads.",
                        flag: "--threads",
                        binding: threadsBinding,
                        placeholder: "Global default"
                    )
                    compactValueField(
                        "Parallel Slots",
                        detail: "Requests processed concurrently.",
                        flag: "--parallel",
                        binding: parallelBinding,
                        placeholder: "Global default"
                    )
                    compactValueField(
                        "Batch Size",
                        detail: "Maximum logical prompt batch.",
                        flag: "--batch-size",
                        binding: batchSizeBinding,
                        placeholder: "Global default"
                    )
                    compactValueField(
                        "Micro Batch Size",
                        detail: "Physical batch used per compute step.",
                        flag: "--ubatch-size",
                        binding: ubatchSizeBinding,
                        placeholder: "Global default"
                    )
                    compactValueField(
                        "Unload Stop Timeout",
                        detail: "Seconds allowed for a clean model unload.",
                        flag: nil,
                        binding: stopTimeoutBinding,
                        placeholder: "10"
                    )

                    configurationField(
                        "Flash Attention",
                        detail: "Inherit the global mode unless this model needs a compatibility override.",
                        flag: "--flash-attn"
                    ) {
                        Picker(
                            "Flash Attention",
                            selection: flashAttentionBinding
                        ) {
                            ForEach(OptionalBooleanChoice.allCases) {
                                Text($0.localizedTitle(locale: locale))
                                    .tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }

                    configurationField(
                        "KV Cache K",
                        detail: "Optional key-cache precision override.",
                        flag: "--cache-type-k"
                    ) {
                        modelKVCacheTypePicker(
                            "KV Cache K",
                            selection: cacheTypeKBinding
                        )
                    }
                    configurationField(
                        "KV Cache V",
                        detail: "Optional value-cache precision override.",
                        flag: "--cache-type-v"
                    ) {
                        modelKVCacheTypePicker(
                            "KV Cache V",
                            selection: cacheTypeVBinding
                        )
                    }
                }
            }
        }
    }

    private var companionModelsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionHeader(
                    "Companion Models",
                    subtitle:
                        "Attach optional GGUF files only when the main model requires them."
                )

                configurationField(
                    "Vision Projector",
                    detail: "Enables image input for a compatible multimodal model.",
                    flag: "--mmproj"
                ) {
                    companionPathControls(
                        path: appModel.profile?.model.mmprojPath,
                        title: localized("Choose a Vision Projector"),
                        set: { $0.model.mmprojPath = $1 }
                    )
                }

                Divider()

                configurationField(
                    "Draft Model",
                    detail: "Optional smaller model used for speculative decoding.",
                    flag: "--model-draft"
                ) {
                    companionPathControls(
                        path: appModel.profile?.model.draftPath,
                        title: localized("Choose a Draft Model"),
                        set: { $0.model.draftPath = $1 }
                    )
                }
            }
        }
    }

    private var samplingSettingsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionHeader(
                    "Sampling Defaults",
                    subtitle:
                        "Set server-side generation defaults only when API clients do not provide their own values."
                )

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 230),
                            alignment: .topLeading
                        )
                    ],
                    alignment: .leading,
                    spacing: 16
                ) {
                    compactValueField(
                        "Temperature",
                        detail: "Higher values increase variety.",
                        flag: "--temp",
                        binding: temperatureBinding
                    )
                    compactValueField(
                        "Top K",
                        detail: "Limit choices to the most likely tokens.",
                        flag: "--top-k",
                        binding: topKBinding
                    )
                    compactValueField(
                        "Top P",
                        detail: "Probability-mass sampling cutoff.",
                        flag: "--top-p",
                        binding: topPBinding
                    )
                    compactValueField(
                        "Min P",
                        detail: "Discard very unlikely tokens.",
                        flag: "--min-p",
                        binding: minPBinding
                    )
                    compactValueField(
                        "Repeat Penalty",
                        detail: "Discourage repeated output.",
                        flag: "--repeat-penalty",
                        binding: repeatPenaltyBinding
                    )
                    compactValueField(
                        "Seed",
                        detail: "Use a fixed value for repeatable output.",
                        flag: "--seed",
                        binding: seedBinding
                    )
                }
            }
        }
    }

    private var systemPromptCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader(
                    "System Prompt",
                    subtitle:
                        "Applied by llama-server when a client does not replace it."
                )
                configurationField(
                    "Prompt",
                    detail: "Leave empty to use the model and client defaults.",
                    flag: "--system-prompt"
                ) {
                    TextEditor(text: systemPromptBinding)
                        .frame(minHeight: 82)
                        .padding(6)
                        .background(
                            .background,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        }
                }
            }
        }
    }

    private var extraArgumentsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                settingsSectionHeader(
                    "Extra Arguments",
                    subtitle:
                        "For llama-server flags that are not available above."
                )
                TextEditor(text: extraArgumentsBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 92)
                    .padding(6)
                    .background(
                        .background,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                Text(
                    "Enter one argument token per line. Tokens are passed directly to llama-server and are never interpreted by a shell."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var generatedConfigurationCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader(
                    "Generated llama-server Config",
                    subtitle:
                        "Technical preview of the configuration LlamaDock will use."
                )

                if let config = appModel.modelsPresetPreview {
                    ScrollView(.horizontal) {
                        Text(config)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .background(
                        .background,
                        in: RoundedRectangle(cornerRadius: 6)
                    )

                    Button("Copy Config", systemImage: "doc.on.doc") {
                        copy(config)
                    }
                } else {
                    Label(
                        appModel.commandError
                            ?? localized("Choose a validated runtime."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitySummary: some View {
        if let runtime = appModel.selectedRuntime {
            let unsupported = configuredFlags.filter {
                runtime.capabilities.support(for: $0) == .unsupported
            }
            if !unsupported.isEmpty {
                Label(
                    "The selected runtime does not support: \(unsupported.joined(separator: ", ")). Remove those values or choose another runtime.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if runtime.capabilities.detection == .unknown {
                Label(
                    "This runtime's help output could not be recognized. Typed settings are marked Unknown and will still be passed through.",
                    systemImage: "questionmark.diamond"
                )
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Compatible with the selected runtime.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
        } else {
            Label(
                "Choose a validated runtime to check parameter support.",
                systemImage: "questionmark.diamond"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func settingsSectionHeader(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func configurationField<Content: View>(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        flag: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)

                Spacer(minLength: 8)

                if let flag {
                    CapabilitySupportBadge(
                        support: appModel.selectedRuntime?.capabilities.support(
                            for: flag
                        ) ?? .unknown
                    )
                }
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compactValueField(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        flag: String?,
        binding: Binding<String>,
        placeholder: LocalizedStringKey = "Runtime default"
    ) -> some View {
        configurationField(title, detail: detail, flag: flag) {
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
    }

    private func modelKVCacheTypePicker(
        _ title: LocalizedStringKey,
        selection: Binding<String>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Global default").tag("")
            ForEach(KVCacheType.allCases, id: \.rawValue) {
                Text($0.rawValue).tag($0.rawValue)
            }
            if
                !selection.wrappedValue.isEmpty,
                KVCacheType(rawValue: selection.wrappedValue) == nil
            {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    private func companionPathControls(
        path: String?,
        title: String,
        set: @escaping (inout LaunchProfile, String?) -> Void
    ) -> some View {
        HStack {
            Text(path ?? localized("Not configured"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(path == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Button("Choose…") {
                chooseCompanion(title: title, set: set)
            }

            if path != nil {
                Button("Clear") {
                    appModel.updateProfile {
                        set(&$0, nil)
                    }
                }
            }
        }
    }

    private var configuredFlags: [String] {
        guard let profile = appModel.profile else {
            return []
        }

        var flags = ["--model"]
        let optionalFlags: [(String, Bool)] = [
            ("--ctx-size", profile.server.contextSize != nil),
            ("--n-gpu-layers", profile.server.gpuLayers != nil),
            ("--threads", profile.server.threads != nil),
            ("--parallel", profile.server.parallel != nil),
            ("--batch-size", profile.server.batchSize != nil),
            ("--ubatch-size", profile.server.ubatchSize != nil),
            ("--flash-attn", profile.server.flashAttention != nil),
            ("--cache-type-k", profile.server.cacheTypeK != nil),
            ("--cache-type-v", profile.server.cacheTypeV != nil),
            ("--system-prompt", profile.server.systemPrompt != nil),
            ("--mmproj", profile.model.mmprojPath != nil),
            ("--model-draft", profile.model.draftPath != nil),
            ("--temp", profile.sampling.temperature != nil),
            ("--top-k", profile.sampling.topK != nil),
            ("--top-p", profile.sampling.topP != nil),
            ("--min-p", profile.sampling.minP != nil),
            ("--repeat-penalty", profile.sampling.repeatPenalty != nil),
            ("--seed", profile.sampling.seed != nil),
        ]
        flags.append(
            contentsOf: optionalFlags.compactMap {
                $0.1 ? $0.0 : nil
            }
        )
        return flags
    }

    private var filteredModels: [LocalModelFile] {
        appModel.localModels.filter { model in
            validationFilter.includes(model)
                && (
                    searchText.isEmpty
                        || model.displayName.localizedCaseInsensitiveContains(
                            searchText
                        )
                        || model.url.path.localizedCaseInsensitiveContains(
                            searchText
                        )
                        || (
                            model.metadata?.architecture
                                .localizedCaseInsensitiveContains(
                                    searchText
                                ) == true
                        )
                )
        }
    }

    private var filteredSettingsProfiles: [LaunchProfile] {
        let query = modelSettingsSearchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else {
            return appModel.profiles
        }
        return appModel.profiles.filter { profile in
            profile.name.localizedCaseInsensitiveContains(query)
                || profile.router.identifier
                    .localizedCaseInsensitiveContains(query)
                || URL(filePath: profile.model.mainPath)
                    .lastPathComponent
                    .localizedCaseInsensitiveContains(query)
        }
    }

    private var hasCustomEverydayPerformanceSettings: Bool {
        guard let profile = appModel.profile else {
            return false
        }
        return profile.server.contextSize != nil
            || profile.server.gpuLayers != nil
    }

    private var hasCustomPerformanceTuningSettings: Bool {
        guard let profile = appModel.profile else {
            return false
        }
        return profile.router.stopTimeout != nil
            || profile.server.threads != nil
            || profile.server.parallel != nil
            || profile.server.batchSize != nil
            || profile.server.ubatchSize != nil
            || profile.server.flashAttention != nil
            || profile.server.cacheTypeK != nil
            || profile.server.cacheTypeV != nil
    }

    private func resetEverydayPerformanceSettings() {
        appModel.updateProfile { profile in
            profile.server.contextSize = nil
            profile.server.gpuLayers = nil
        }
    }

    private func resetPerformanceTuningSettings() {
        appModel.updateProfile { profile in
            profile.router.stopTimeout = nil
            profile.server.threads = nil
            profile.server.parallel = nil
            profile.server.batchSize = nil
            profile.server.ubatchSize = nil
            profile.server.flashAttention = nil
            profile.server.cacheTypeK = nil
            profile.server.cacheTypeV = nil
        }
    }

    private var profileNameBinding: Binding<String> {
        Binding(
            get: { appModel.profile?.name ?? "" },
            set: { value in
                appModel.updateProfile { $0.name = value }
            }
        )
    }

    private var modelAvailabilityBinding:
        Binding<ModelAvailabilityChoice>
    {
        Binding(
            get: {
                guard let profile = appModel.profile else {
                    return .off
                }
                guard profile.router.isEnabled else {
                    return .off
                }
                return profile.router.loadOnStartup
                    ? .atStartup
                    : .onDemand
            },
            set: { availability in
                appModel.updateProfile { profile in
                    switch availability {
                    case .off:
                        profile.router.isEnabled = false
                        profile.router.loadOnStartup = false
                    case .onDemand:
                        profile.router.isEnabled = true
                        profile.router.loadOnStartup = false
                    case .atStartup:
                        profile.router.isEnabled = true
                        profile.router.loadOnStartup = true
                    }
                }
            }
        )
    }

    private var routerIdentifierBinding: Binding<String> {
        Binding(
            get: { appModel.profile?.router.identifier ?? "" },
            set: { value in
                appModel.updateProfile {
                    $0.router.identifier = value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }
            }
        )
    }

    private var stopTimeoutBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.router.stopTimeout },
            set: { $0.router.stopTimeout = $1 }
        )
    }

    private var contextSizeBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.server.contextSize },
            set: { $0.server.contextSize = $1 }
        )
    }

    private var gpuLayersBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.server.gpuLayers },
            set: { $0.server.gpuLayers = $1 }
        )
    }

    private var threadsBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.server.threads },
            set: { $0.server.threads = $1 }
        )
    }

    private var parallelBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.server.parallel },
            set: { $0.server.parallel = $1 }
        )
    }

    private var batchSizeBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.server.batchSize },
            set: { $0.server.batchSize = $1 }
        )
    }

    private var ubatchSizeBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.server.ubatchSize },
            set: { $0.server.ubatchSize = $1 }
        )
    }

    private var flashAttentionBinding: Binding<OptionalBooleanChoice> {
        Binding(
            get: {
                switch appModel.profile?.server.flashAttention {
                case .some(true):
                    .enabled
                case .some(false):
                    .disabled
                case .none:
                    .runtimeDefault
                }
            },
            set: { value in
                appModel.updateProfile {
                    $0.server.flashAttention = value.value
                }
            }
        )
    }

    private var cacheTypeKBinding: Binding<String> {
        optionalTextBinding(
            get: { $0.server.cacheTypeK },
            set: { $0.server.cacheTypeK = $1 }
        )
    }

    private var cacheTypeVBinding: Binding<String> {
        optionalTextBinding(
            get: { $0.server.cacheTypeV },
            set: { $0.server.cacheTypeV = $1 }
        )
    }

    private var temperatureBinding: Binding<String> {
        optionalDoubleBinding(
            get: { $0.sampling.temperature },
            set: { $0.sampling.temperature = $1 }
        )
    }

    private var topKBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.sampling.topK },
            set: { $0.sampling.topK = $1 }
        )
    }

    private var topPBinding: Binding<String> {
        optionalDoubleBinding(
            get: { $0.sampling.topP },
            set: { $0.sampling.topP = $1 }
        )
    }

    private var minPBinding: Binding<String> {
        optionalDoubleBinding(
            get: { $0.sampling.minP },
            set: { $0.sampling.minP = $1 }
        )
    }

    private var repeatPenaltyBinding: Binding<String> {
        optionalDoubleBinding(
            get: { $0.sampling.repeatPenalty },
            set: { $0.sampling.repeatPenalty = $1 }
        )
    }

    private var seedBinding: Binding<String> {
        optionalIntegerBinding(
            get: { $0.sampling.seed },
            set: { $0.sampling.seed = $1 }
        )
    }

    private var systemPromptBinding: Binding<String> {
        optionalTextBinding(
            get: { $0.server.systemPrompt },
            set: { $0.server.systemPrompt = $1 },
            trimmingWhitespace: false
        )
    }

    private var extraArgumentsBinding: Binding<String> {
        Binding(
            get: {
                appModel.profile?.extraArguments.joined(separator: "\n") ?? ""
            },
            set: { value in
                let tokens = value
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                appModel.updateProfile { $0.extraArguments = tokens }
            }
        )
    }

    private func optionalTextBinding(
        get: @escaping (LaunchProfile) -> String?,
        set: @escaping (inout LaunchProfile, String?) -> Void,
        trimmingWhitespace: Bool = true
    ) -> Binding<String> {
        Binding(
            get: {
                appModel.profile.flatMap(get) ?? ""
            },
            set: { value in
                appModel.updateProfile { profile in
                    let candidate = trimmingWhitespace
                        ? value.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        : value
                    set(
                        &profile,
                        candidate.isEmpty ? nil : candidate
                    )
                }
            }
        )
    }

    private func optionalIntegerBinding(
        get: @escaping (LaunchProfile) -> Int?,
        set: @escaping (inout LaunchProfile, Int?) -> Void
    ) -> Binding<String> {
        Binding(
            get: {
                appModel.profile.flatMap(get).map {
                    String($0)
                } ?? ""
            },
            set: { value in
                let candidate = value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard candidate.isEmpty || Int(candidate) != nil else {
                    return
                }
                appModel.updateProfile {
                    set(&$0, candidate.isEmpty ? nil : Int(candidate))
                }
            }
        )
    }

    private func optionalDoubleBinding(
        get: @escaping (LaunchProfile) -> Double?,
        set: @escaping (inout LaunchProfile, Double?) -> Void
    ) -> Binding<String> {
        Binding(
            get: {
                appModel.profile.flatMap(get).map {
                    String($0)
                } ?? ""
            },
            set: { value in
                let candidate = value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard candidate.isEmpty || Double(candidate) != nil else {
                    return
                }
                appModel.updateProfile {
                    set(&$0, candidate.isEmpty ? nil : Double(candidate))
                }
            }
        )
    }

    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.title = localized("Add Model Folders")
        panel.message = localized("""
            LlamaDock stores a security-scoped bookmark and scans GGUF \
            metadata without moving model files.
            """)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK else {
            return
        }
        let urls = panel.urls
        Task {
            for url in urls {
                await appModel.addModelDirectory(url)
            }
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = localized("Open a GGUF Model")
        panel.message = localized("""
            This creates a profile for one file. Add its folder separately \
            if you want it restored in the model library.
            """)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        appModel.selectModel(url)
    }

    private func chooseCompanion(
        title: String,
        set: @escaping (inout LaunchProfile, String?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        appModel.updateProfile {
            set(
                &$0,
                url.standardizedFileURL.path
            )
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = localized("Import a LlamaDock Profile")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            await appModel.importProfile(from: url)
        }
    }

    private func exportProfile() {
        guard let profile = appModel.profile else {
            return
        }
        let panel = NSSavePanel()
        panel.title = localized("Export LlamaDock Profile")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = profile.name.replacingOccurrences(
            of: "/",
            with: "-"
        ) + ".json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            await appModel.exportSelectedProfile(to: url)
        }
    }

    private func reveal(
        _ url: URL
    ) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func trashConfirmationMessage(
        for model: LocalModelFile
    ) -> String {
        let referenceCount = appModel.profileReferenceCount(
            for: model
        )
        let profileWarning: String
        if referenceCount == 0 {
            profileWarning = localized(
                "No saved profiles reference this file."
            )
        } else {
            profileWarning = localized(
                "\(referenceCount) saved profiles will retain this path and cannot use it until the file is restored or replaced."
            )
        }
        return localized("""
            LlamaDock will move only \(model.url.lastPathComponent) to the \
            macOS Trash. It will not delete the containing folder or other \
            split/companion files. \(profileWarning)
            """)
    }

    private func copy(
        _ value: String
    ) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func byteCount(
        _ value: UInt64
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max)))
        )
    }

    private func parameterCount(
        _ value: UInt64
    ) -> String {
        switch value {
        case 1_000_000_000...:
            String(
                format: "%.2fB",
                Double(value) / 1_000_000_000
            )
        case 1_000_000...:
            String(
                format: "%.2fM",
                Double(value) / 1_000_000
            )
        case 1_000...:
            String(
                format: "%.2fK",
                Double(value) / 1_000
            )
        default:
            value.formatted(.number.locale(locale))
        }
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

enum ModelBrowserSplitLayout {
    static let listMinWidth: CGFloat = 220
    static let listIdealWidth: CGFloat = 280
    static let listMaxWidth: CGFloat = 320
    static let detailMinWidth: CGFloat = 440
}

private struct ModelLibraryRow: View {
    let model: LocalModelFile
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(
                        model.role.localizedDisplayName(locale: locale)
                    )
                    if let architecture = model.metadata?.architecture {
                        Text("•")
                        Text(architecture)
                    }
                    if let quantization = model.metadata?.quantization {
                        Text("•")
                        Text(quantization)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if case .invalid = model.validation {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        "Invalid or unsupported GGUF"
                    )
                    .help("Invalid or unsupported GGUF")
            } else if model.metadata?.shard != nil {
                Text("SPLIT")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var icon: String {
        switch model.role {
        case .main:
            "brain"
        case .mmproj:
            "eye"
        case .draft:
            "hare"
        case .adapter:
            "puzzlepiece"
        case .auxiliary:
            "doc"
        }
    }

    private var iconColor: Color {
        model.validation == .valid ? .accentColor : .orange
    }
}

private struct ModelStatusBadge: View {
    let model: LocalModelFile
    @Environment(\.locale) private var locale

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var title: String {
        switch model.validation {
        case .valid:
            model.role.localizedDisplayName(locale: locale)
        case .invalid:
            appLocalizedString("Invalid", locale: locale)
        }
    }

    private var color: Color {
        model.validation == .valid ? .green : .orange
    }
}

private enum ModelSource:
    String,
    CaseIterable,
    Identifiable
{
    case local
    case huggingFace
    case modelScope

    var id: String {
        rawValue
    }

    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .local:
            appLocalizedString("Local Library", locale: locale)
        case .huggingFace:
            appLocalizedString("Hugging Face", locale: locale)
        case .modelScope:
            appLocalizedString("ModelScope", locale: locale)
        }
    }

    var icon: String {
        switch self {
        case .local:
            "internaldrive"
        case .huggingFace:
            "globe"
        case .modelScope:
            "network"
        }
    }
}

private enum ModelValidationFilter:
    String,
    CaseIterable,
    Identifiable
{
    case all
    case valid
    case invalid

    var id: String {
        rawValue
    }

    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .all:
            appLocalizedString("All Files", locale: locale)
        case .valid:
            appLocalizedString("Valid", locale: locale)
        case .invalid:
            appLocalizedString("Invalid", locale: locale)
        }
    }

    func includes(
        _ model: LocalModelFile
    ) -> Bool {
        switch (self, model.validation) {
        case (.all, _), (.valid, .valid), (.invalid, .invalid):
            true
        case (.valid, .invalid), (.invalid, .valid):
            false
        }
    }
}

private extension LocalModelRole {
    func localizedDisplayName(locale: Locale) -> String {
        switch self {
        case .main:
            appLocalizedString("Main", locale: locale)
        case .mmproj:
            appLocalizedString("Vision Projector", locale: locale)
        case .draft:
            appLocalizedString("Draft", locale: locale)
        case .adapter:
            appLocalizedString("Adapter", locale: locale)
        case .auxiliary:
            appLocalizedString("Auxiliary", locale: locale)
        }
    }
}

enum ModelPageMode {
    case browser
    case settings
}

private struct ModelSettingRow: View {
    let profile: LaunchProfile
    let runtimeModel: LlamaServerModel?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: profile.router.isEnabled
                    ? "cube.transparent.fill"
                    : "cube.transparent"
            )
            .foregroundStyle(
                profile.router.isEnabled
                    ? Color.accentColor
                    : Color.secondary
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)
                Text(profile.router.identifier)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(
                    URL(filePath: profile.model.mainPath)
                        .lastPathComponent
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            ServerModelStateBadge(
                state: runtimeModel?.state,
                isEnabled: profile.router.isEnabled,
                compact: true
            )
        }
        .padding(.vertical, 3)
    }
}

private struct ServerModelStateBadge: View {
    let state: LlamaServerModelState?
    let isEnabled: Bool
    var compact = false
    @Environment(\.locale) private var locale

    var body: some View {
        if compact {
            label
                .labelStyle(.iconOnly)
        } else {
            label
                .labelStyle(.titleAndIcon)
        }
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .help(title)
    }

    private var title: String {
        guard isEnabled else {
            return appLocalizedString("Disabled", locale: locale)
        }
        switch state {
        case .loaded:
            return appLocalizedString("Loaded", locale: locale)
        case .loading:
            return appLocalizedString("Loading", locale: locale)
        case .sleeping:
            return appLocalizedString("Sleeping", locale: locale)
        case .downloading:
            return appLocalizedString("Downloading", locale: locale)
        case .failed:
            return appLocalizedString("Failed", locale: locale)
        case .unloaded:
            return appLocalizedString("Available", locale: locale)
        case .unknown(let value):
            return value
        case nil:
            return appLocalizedString("Configured", locale: locale)
        }
    }

    private var systemImage: String {
        guard isEnabled else {
            return "pause.circle"
        }
        switch state {
        case .loaded:
            return "circle.fill"
        case .loading, .downloading:
            return "arrow.triangle.2.circlepath"
        case .sleeping:
            return "moon.zzz"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .unloaded, .unknown, nil:
            return "circle"
        }
    }

    private var color: Color {
        guard isEnabled else {
            return .secondary
        }
        switch state {
        case .loaded:
            return .green
        case .loading, .downloading:
            return .blue
        case .sleeping:
            return .indigo
        case .failed:
            return .red
        case .unloaded, .unknown, nil:
            return .secondary
        }
    }
}

private enum ModelAvailabilityChoice:
    String,
    CaseIterable,
    Identifiable
{
    case off
    case onDemand
    case atStartup

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .off:
            "Off"
        case .onDemand:
            "On Demand"
        case .atStartup:
            "At Startup"
        }
    }

    var systemImage: String {
        switch self {
        case .off:
            "pause.circle"
        case .onDemand:
            "bolt"
        case .atStartup:
            "power"
        }
    }
}

private enum OptionalBooleanChoice:
    String,
    CaseIterable,
    Identifiable
{
    case runtimeDefault
    case enabled
    case disabled

    var id: String {
        rawValue
    }

    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .runtimeDefault:
            appLocalizedString("Global default", locale: locale)
        case .enabled:
            appLocalizedString("On", locale: locale)
        case .disabled:
            appLocalizedString("Off", locale: locale)
        }
    }

    var value: Bool? {
        switch self {
        case .runtimeDefault:
            nil
        case .enabled:
            true
        case .disabled:
            false
        }
    }
}

private enum ProfileEditorLevel:
    Int,
    CaseIterable,
    Identifiable
{
    case basic
    case performance
    case advanced

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .basic:
            "Essentials"
        case .performance:
            "Performance"
        case .advanced:
            "Expert"
        }
    }

    var description: LocalizedStringKey {
        switch self {
        case .basic:
            "Set availability, names, context size, and GPU offload."
        case .performance:
            "Also tune threads, batching, cache types, and unload behavior."
        case .advanced:
            "Also configure companion models, generation defaults, prompts, and raw arguments."
        }
    }

    func includes(_ level: Self) -> Bool {
        rawValue >= level.rawValue
    }
}

struct CapabilitySupportBadge: View {
    let support: RuntimeFlagSupport
    @Environment(\.locale) private var locale

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .help(helpText)
    }

    private var title: String {
        switch support {
        case .supported:
            appLocalizedString("Supported", locale: locale)
        case .unsupported:
            appLocalizedString("Unsupported", locale: locale)
        case .unknown:
            appLocalizedString("Unknown", locale: locale)
        }
    }

    private var icon: String {
        switch support {
        case .supported:
            "checkmark.circle"
        case .unsupported:
            "xmark.circle"
        case .unknown:
            "questionmark.diamond"
        }
    }

    private var color: Color {
        switch support {
        case .supported:
            .green
        case .unsupported:
            .orange
        case .unknown:
            .secondary
        }
    }

    private var helpText: String {
        switch support {
        case .supported:
            appLocalizedString(
                "The selected runtime advertises this flag.",
                locale: locale
            )
        case .unsupported:
            appLocalizedString(
                "The selected runtime help does not advertise this flag.",
                locale: locale
            )
        case .unknown:
            appLocalizedString(
                "Runtime capability detection is unavailable or inconclusive.",
                locale: locale
            )
        }
    }
}

#Preview {
    ModelsView()
        .environment(AppModel())
        .frame(width: 980, height: 720)
}
