import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LlamadockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate
    @State private var appModel = AppModel()
    @AppStorage(AppLanguage.storageKey)
    private var appLanguage = AppLanguage.system
    @AppStorage(AppAppearance.showMenuBarIconKey)
    private var showMenuBarIcon = true
    @AppStorage(AppAppearance.showDockIconKey)
    private var showDockIcon = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appModel)
                .environment(\.locale, appLanguage.locale)
                .task {
                    appDelegate.shutdownOwnedServer = {
                        await appModel.shutdown()
                    }
                    appDelegate.setDockIconVisible(showDockIcon)
                    await appModel.bootstrap()
                }
                .onChange(of: showDockIcon) {
                    appDelegate.setDockIconVisible(showDockIcon)
                }
                .onChange(of: showMenuBarIcon) {
                    if !showMenuBarIcon && !showDockIcon {
                        showDockIcon = true
                    }
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            LlamaDockCommands(
                appModel: appModel,
                locale: appLanguage.locale
            )
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .environment(\.locale, appLanguage.locale)
        }

        MenuBarExtra(
            isInserted: $showMenuBarIcon
        ) {
            ServiceMenuBarView()
                .environment(appModel)
                .environment(\.locale, appLanguage.locale)
        } label: {
            Label {
                Text("LlamaDock")
            } icon: {
                Image(
                    systemName:
                        appModel.serviceStatus.menuBarSystemImage
                )
            }
            .accessibilityLabel(
                Text(
                    "LlamaDock server \(appModel.serviceStatus.localizedString(locale: appLanguage.locale))"
                )
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private struct LlamaDockCommands: Commands {
    let appModel: AppModel
    let locale: Locale

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(localized("Open GGUF Model…")) {
                openModel()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandMenu(localized("Navigate")) {
            Button(localized("Overview")) {
                appModel.selectedSection = .overview
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button(localized("Service")) {
                appModel.selectedSection = .service
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button(localized("Logs")) {
                appModel.selectedSection = .logs
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button(localized("Models")) {
                appModel.selectedSection = .models
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button(localized("Downloads")) {
                appModel.selectedSection = .downloads
            }
            .keyboardShortcut("5", modifiers: [.command])

            Button(localized("Runtime")) {
                appModel.selectedSection = .runtimes
            }
            .keyboardShortcut("6", modifiers: [.command])

            Divider()

            Button(localized("Server Logs")) {
                appModel.selectedSection = .logs
            }
            .keyboardShortcut(
                "l",
                modifiers: [.command, .shift]
            )
        }

        CommandMenu(localized("Server")) {
            Button(localized("Start Server")) {
                Task {
                    await appModel.startServer()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!appModel.canStartServer)

            Button(localized("Stop Server")) {
                Task {
                    await appModel.stopServer()
                }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!appModel.canStopServer)

            Button(localized("Restart Server")) {
                Task {
                    await appModel.restartServer()
                }
            }
            .keyboardShortcut(
                "r",
                modifiers: [.command, .option]
            )
            .disabled(!appModel.canRestartServer)
        }
    }

    private func openModel() {
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
        appModel.selectedSection = .models
        appModel.selectModel(url)
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}
