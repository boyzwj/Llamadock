import AppKit
import LlamadockCore
import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var validationFilter = ModelValidationFilter.all

    var body: some View {
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
        .navigationTitle("Models")
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search local models"
        )
        .toolbar {
            ToolbarItemGroup {
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
                }
            }
        }
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
                        let profile = appModel.profile,
                        profile.model.mainPath == model.url.path
                    {
                        profileEditor
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

    private var profileEditor: some View {
        GroupBox("Launch Profile") {
            Form {
                TextField("Profile Name", text: profileNameBinding)

                Section("Server") {
                    TextField("Host", text: hostBinding)
                    TextField("Port", value: portBinding, format: .number)
                    TextField(
                        "Context Size (0 = runtime default)",
                        value: contextSizeBinding,
                        format: .number
                    )
                    TextField(
                        "GPU Layers (0 = runtime default)",
                        value: gpuLayersBinding,
                        format: .number
                    )
                    TextField(
                        "Threads (0 = runtime default)",
                        value: threadsBinding,
                        format: .number
                    )
                }

                Section("Extra Arguments") {
                    TextEditor(text: extraArgumentsBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                    Text(
                        "Enter one argument token per line. Tokens are never interpreted by a shell."
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

    private var contextSizeBinding: Binding<Int> {
        optionalPositiveIntegerBinding(
            get: { $0.server.contextSize },
            set: { $0.server.contextSize = $1 }
        )
    }

    private var gpuLayersBinding: Binding<Int> {
        optionalPositiveIntegerBinding(
            get: { $0.server.gpuLayers },
            set: { $0.server.gpuLayers = $1 }
        )
    }

    private var threadsBinding: Binding<Int> {
        optionalPositiveIntegerBinding(
            get: { $0.server.threads },
            set: { $0.server.threads = $1 }
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

    private func optionalPositiveIntegerBinding(
        get: @escaping (LaunchProfileProxy) -> Int?,
        set: @escaping (inout LaunchProfileProxy, Int?) -> Void
    ) -> Binding<Int> {
        Binding(
            get: {
                guard let profile = appModel.profile else {
                    return 0
                }
                return get(LaunchProfileProxy(profile)) ?? 0
            },
            set: { value in
                appModel.updateProfile { profile in
                    var proxy = LaunchProfileProxy(profile)
                    set(&proxy, value > 0 ? value : nil)
                    profile = proxy.profile
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

    private func reveal(
        _ url: URL
    ) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

private struct LaunchProfileProxy {
    var profile: LaunchProfile

    init(_ profile: LaunchProfile) {
        self.profile = profile
    }

    var server: ServerOptions {
        get { profile.server }
        set { profile.server = newValue }
    }
}

#Preview {
    ModelsView()
        .environment(AppModel())
        .frame(width: 980, height: 720)
}
