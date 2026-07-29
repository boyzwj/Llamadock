import SwiftUI

@main
struct LlamadockApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 1_080, height: 720)

        Settings {
            SettingsView()
        }
    }
}
