import SwiftUI

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

        Settings {
            SettingsView()
        }
    }
}
