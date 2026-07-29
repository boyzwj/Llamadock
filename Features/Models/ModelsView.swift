import AppKit
import LlamadockCore
import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.profile == nil {
                ContentUnavailableView {
                    Label("No Model Selected", systemImage: "externaldrive")
                } description: {
                    Text(
                        "Choose a local GGUF file. LlamaDock keeps the model in its original location."
                    )
                } actions: {
                    Button("Choose GGUF…") {
                        chooseModel()
                    }
                }
            } else {
                profileEditor
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItemGroup {
                Button("Choose GGUF", systemImage: "plus") {
                    chooseModel()
                }

                if let modelURL = appModel.selectedModelURL {
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [modelURL]
                        )
                    }
                }
            }
        }
    }

    private var profileEditor: some View {
        ScrollView {
            Form {
                Section("Model") {
                    LabeledContent("Path") {
                        Text(appModel.selectedModelURL?.path ?? "Missing")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    TextField("Profile Name", text: profileNameBinding)
                }

                Section("Server") {
                    TextField("Host", text: hostBinding)
                    TextField("Port", value: portBinding, format: .number)
                    TextField(
                        "Context Size (0 = runtime default)",
                        value: contextSizeBinding,
                        format: .number
                    )
                    TextField(
                        "GPU Layers (blank/default = 0)",
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
                        .frame(minHeight: 90)
                    Text("Enter one argument token per line. This is never interpreted as a shell command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Generated Command Preview") {
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
                                ?? "Choose a validated runtime to generate the command.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
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

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GGUF Model"
        panel.message = "The model remains a normal file in its current directory."
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

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
        .frame(width: 800, height: 700)
}
