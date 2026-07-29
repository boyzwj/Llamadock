import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            List(AppSection.allCases, selection: $appModel.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("LlamaDock")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert(
            "LlamaDock",
            isPresented: Binding(
                get: { appModel.visibleError != nil },
                set: { isPresented in
                    if !isPresented {
                        appModel.visibleError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                appModel.visibleError = nil
            }
        } message: {
            Text(appModel.visibleError ?? "An unexpected error occurred.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appModel.selectedSection {
        case .overview:
            OverviewView()
        case .runtimes:
            RuntimesView()
        case .models:
            ModelsView()
        case .servers:
            ServersView()
        case nil:
            ContentUnavailableView(
                "Choose a Section",
                systemImage: "sidebar.left",
                description: Text("Select a destination from the sidebar.")
            )
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
