import AppKit
import LlamadockCore
import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var validationFilter = ModelValidationFilter.all
    @State private var source = ModelSource.local
    @State private var pendingModelTrash: LocalModelFile?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Model Source", selection: $source) {
                ForEach(ModelSource.allCases) { source in
                    Label(source.title, systemImage: source.icon)
                        .tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .padding(.vertical, 10)

            Divider()

            switch source {
            case .local:
                localLibrary
            case .huggingFace:
                HuggingFaceModelsView()
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItemGroup {
                if source == .local {
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
                        .help(
                            appModel.localModelTrashBlockReason(
                                model
                            ) ?? "Move this GGUF file to the system Trash."
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
                        .frame(minWidth: 300, idealWidth: 360)
                    modelDetail
                        .frame(minWidth: 480)
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
                        Text(filter.title).tag(filter)
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
                            Button("Create Default Profile") {
                                appModel.createProfile(for: model)
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
                        "Scanned \(snapshot.roots.count) \(snapshot.roots.count == 1 ? "root" : "roots")"
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

                    if
                        model.validation == .valid,
                        model.role == .main
                    {
                        profilesCard(model)

                        if appModel.profiles(for: model).contains(
                            where: {
                                $0.id == appModel.selectedProfileID
                            }
                        ) {
                            profileEditor
                        }
                    }
                }
                .padding(22)
            }
        } else {
            ContentUnavailableView(
                "Choose a Model",
                systemImage: "sidebar.right",
                description: Text(
                    "Select a GGUF file to inspect metadata and create a profile."
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
                    Button("Create Default Profile") {
                        appModel.createProfile(for: model)
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
                    ) ?? "Move this GGUF file to the system Trash."
                )
            }

            if case .invalid(let reason) = model.validation {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func metadataCard(
        _ model: LocalModelFile
    ) -> some View {
        GroupBox("GGUF Metadata") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                metadataRow("Role", model.role.displayName)
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
                            ?? "Unknown"
                    )
                    metadataRow(
                        "Context",
                        metadata.contextLength.map {
                            $0.formatted()
                        } ?? "Unknown"
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
                        metadata.hasChatTemplate ? "Present" : "Not declared"
                    )
                    if let shard = metadata.shard {
                        metadataRow(
                            "Split",
                            "Shard \(shard.zeroBasedIndex + 1) of \(shard.count)"
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private func metadataRow(
        _ title: String,
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
                        "\(modelProfiles.count) saved \(modelProfiles.count == 1 ? "profile" : "profiles"). The most recently edited profile appears first."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private var profileEditor: some View {
        GroupBox("Launch Profile") {
            VStack(alignment: .leading, spacing: 12) {
                capabilitySummary

                Form {
                    Section("Identity and Models") {
                        TextField("Profile Name", text: profileNameBinding)

                        capabilityField("Model Path", flag: "--model") {
                            Text(appModel.profile?.model.mainPath ?? "")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        capabilityField("Alias", flag: "--alias") {
                            TextField(
                                "Runtime default",
                                text: aliasBinding
                            )
                        }

                        capabilityField("Vision Projector", flag: "--mmproj") {
                            companionPathControls(
                                path: appModel.profile?.model.mmprojPath,
                                title: "Choose a Vision Projector",
                                set: {
                                    $0.model.mmprojPath = $1
                                }
                            )
                        }

                        capabilityField("Draft Model", flag: "--model-draft") {
                            companionPathControls(
                                path: appModel.profile?.model.draftPath,
                                title: "Choose a Draft Model",
                                set: {
                                    $0.model.draftPath = $1
                                }
                            )
                        }
                    }

                    Section("Network") {
                        capabilityField("Host", flag: "--host") {
                            TextField("Host", text: hostBinding)
                        }
                        capabilityField("Port", flag: "--port") {
                            TextField(
                                "Port",
                                value: portBinding,
                                format: .number
                            )
                        }
                    }

                    Section("Performance") {
                        optionalIntegerField(
                            "Context Size",
                            flag: "--ctx-size",
                            binding: contextSizeBinding
                        )
                        optionalIntegerField(
                            "GPU Layers",
                            flag: "--n-gpu-layers",
                            binding: gpuLayersBinding
                        )
                        optionalIntegerField(
                            "Threads",
                            flag: "--threads",
                            binding: threadsBinding
                        )
                        optionalIntegerField(
                            "Parallel Slots",
                            flag: "--parallel",
                            binding: parallelBinding
                        )
                        optionalIntegerField(
                            "Batch Size",
                            flag: "--batch-size",
                            binding: batchSizeBinding
                        )
                        optionalIntegerField(
                            "Micro Batch Size",
                            flag: "--ubatch-size",
                            binding: ubatchSizeBinding
                        )

                        capabilityField(
                            "Flash Attention",
                            flag: "--flash-attn"
                        ) {
                            Picker(
                                "Flash Attention",
                                selection: flashAttentionBinding
                            ) {
                                ForEach(OptionalBooleanChoice.allCases) {
                                    Text($0.title).tag($0)
                                }
                            }
                            .labelsHidden()
                        }

                        capabilityField("KV Cache K", flag: "--cache-type-k") {
                            TextField(
                                "Runtime default",
                                text: cacheTypeKBinding
                            )
                        }
                        capabilityField("KV Cache V", flag: "--cache-type-v") {
                            TextField(
                                "Runtime default",
                                text: cacheTypeVBinding
                            )
                        }
                    }

                    Section("Sampling") {
                        optionalDecimalField(
                            "Temperature",
                            flag: "--temp",
                            binding: temperatureBinding
                        )
                        optionalIntegerField(
                            "Top K",
                            flag: "--top-k",
                            binding: topKBinding
                        )
                        optionalDecimalField(
                            "Top P",
                            flag: "--top-p",
                            binding: topPBinding
                        )
                        optionalDecimalField(
                            "Min P",
                            flag: "--min-p",
                            binding: minPBinding
                        )
                        optionalDecimalField(
                            "Repeat Penalty",
                            flag: "--repeat-penalty",
                            binding: repeatPenaltyBinding
                        )
                        optionalIntegerField(
                            "Seed",
                            flag: "--seed",
                            binding: seedBinding
                        )
                    }

                    Section("System Prompt") {
                        capabilityField(
                            "Prompt",
                            flag: "--system-prompt"
                        ) {
                            TextEditor(text: systemPromptBinding)
                                .frame(minHeight: 70)
                        }
                    }

                    Section("Extra Arguments") {
                        TextEditor(text: extraArgumentsBinding)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                        Text(
                            "Enter one argument token per line. Tokens are passed directly to llama-server and are never interpreted by a shell."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Generated Command") {
                        if let command = appModel.commandPreview {
                            Text(command)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy Command", systemImage: "doc.on.doc") {
                                copy(command)
                            }
                        } else {
                            Label(
                                appModel.commandError
                                    ?? "Choose a validated runtime.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .padding(.top, 4)
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
                    "Configured typed settings are supported by the selected runtime.",
                    systemImage: "checkmark.circle.fill"
                )
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

    private func capabilityField<Content: View>(
        _ title: String,
        flag: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent {
            HStack {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                CapabilitySupportBadge(
                    support: appModel.selectedRuntime?.capabilities.support(
                        for: flag
                    ) ?? .unknown
                )
            }
        } label: {
            Text(title)
        }
    }

    private func optionalIntegerField(
        _ title: String,
        flag: String,
        binding: Binding<String>
    ) -> some View {
        capabilityField(title, flag: flag) {
            TextField("Runtime default", text: binding)
        }
    }

    private func optionalDecimalField(
        _ title: String,
        flag: String,
        binding: Binding<String>
    ) -> some View {
        capabilityField(title, flag: flag) {
            TextField("Runtime default", text: binding)
        }
    }

    private func companionPathControls(
        path: String?,
        title: String,
        set: @escaping (inout LaunchProfile, String?) -> Void
    ) -> some View {
        HStack {
            Text(path ?? "Not configured")
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

        var flags = ["--model", "--host", "--port"]
        let optionalFlags: [(String, Bool)] = [
            ("--alias", profile.server.alias != nil),
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

    private var profileNameBinding: Binding<String> {
        Binding(
            get: { appModel.profile?.name ?? "" },
            set: { value in
                appModel.updateProfile { $0.name = value }
            }
        )
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { appModel.profile?.server.host ?? "127.0.0.1" },
            set: { value in
                appModel.updateProfile { $0.server.host = value }
            }
        )
    }

    private var aliasBinding: Binding<String> {
        optionalTextBinding(
            get: { $0.server.alias },
            set: { $0.server.alias = $1 }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { Int(appModel.profile?.server.port ?? 8_080) },
            set: { value in
                let bounded = min(max(value, 1), Int(UInt16.max))
                appModel.updateProfile {
                    $0.server.port = UInt16(bounded)
                }
            }
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
        panel.title = "Add Model Folders"
        panel.message = """
            LlamaDock stores a security-scoped bookmark and scans GGUF \
            metadata without moving model files.
            """
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
        panel.title = "Open a GGUF Model"
        panel.message = """
            This creates a profile for one file. Add its folder separately \
            if you want it restored in the model library.
            """
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
        panel.title = "Import a LlamaDock Profile"
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
        panel.title = "Export LlamaDock Profile"
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
            profileWarning = "No saved Profile references this file."
        } else {
            profileWarning = """
                \(referenceCount) saved \
                \(referenceCount == 1 ? "Profile" : "Profiles") will retain \
                this path and cannot use it until the file is restored or \
                replaced.
                """
        }
        return """
            LlamaDock will move only \(model.url.lastPathComponent) to the \
            macOS Trash. It will not delete the containing folder or other \
            split/companion files. \(profileWarning)
            """
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
        ByteCountFormatter.string(
            fromByteCount: Int64(
                min(value, UInt64(Int64.max))
            ),
            countStyle: .file
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
            value.formatted()
        }
    }
}

private struct ModelLibraryRow: View {
    let model: LocalModelFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(model.role.displayName)
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
            model.role.displayName
        case .invalid:
            "Invalid"
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

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .local:
            "Local Library"
        case .huggingFace:
            "Hugging Face"
        }
    }

    var icon: String {
        switch self {
        case .local:
            "internaldrive"
        case .huggingFace:
            "globe"
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

    var title: String {
        switch self {
        case .all:
            "All Files"
        case .valid:
            "Valid"
        case .invalid:
            "Invalid"
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
    var displayName: String {
        switch self {
        case .main:
            "Main"
        case .mmproj:
            "Vision Projector"
        case .draft:
            "Draft"
        case .adapter:
            "Adapter"
        case .auxiliary:
            "Auxiliary"
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

    var title: String {
        switch self {
        case .runtimeDefault:
            "Runtime default"
        case .enabled:
            "On"
        case .disabled:
            "Off"
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

private struct CapabilitySupportBadge: View {
    let support: RuntimeFlagSupport

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
            "Supported"
        case .unsupported:
            "Unsupported"
        case .unknown:
            "Unknown"
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
            "The selected runtime advertises this flag."
        case .unsupported:
            "The selected runtime help does not advertise this flag."
        case .unknown:
            "Runtime capability detection is unavailable or inconclusive."
        }
    }
}

#Preview {
    ModelsView()
        .environment(AppModel())
        .frame(width: 980, height: 720)
}
