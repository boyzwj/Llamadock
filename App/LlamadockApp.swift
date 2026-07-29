import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LlamadockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .task {
                    appDelegate.shutdownOwnedServer = {
                        await appModel.shutdown()
                    }
                    await appModel.bootstrap()
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            LlamaDockCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

@MainActor
private struct LlamaDockCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open GGUF Model…") {
                openModel()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandMenu("Navigate") {
            Button("Overview") {
                appModel.selectedSection = .overview
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Runtimes") {
                appModel.selectedSection = .runtimes
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("Models") {
                appModel.selectedSection = .models
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("Server Logs") {
                appModel.selectedSection = .servers
            }
            .keyboardShortcut(
                "l",
                modifiers: [.command, .shift]
            )
        }

        CommandMenu("Server") {
            Button("Start Server") {
                Task {
                    await appModel.startServer()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!appModel.canStartServer)

            Button("Stop Server") {
                Task {
                    await appModel.stopServer()
                }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!appModel.canStopServer)

            Button("Restart Server") {
                Task {
                    await appModel.restartServer()
                }
            }
            .keyboardShortcut(
                "r",
                modifiers: [.command, .option]
            )
            .disabled(!appModel.canStopServer)
        }
    }

    private func openModel() {
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
        appModel.selectedSection = .models
        appModel.selectModel(url)
    }
}
