import LlamadockCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            List(selection: $appModel.selectedSection) {
                ForEach(
                    ProductNavigationGroup.allCases,
                    id: \.self
                ) { group in
                    Section(AppSection.localizedGroupTitle(group)) {
                        ForEach(AppSection.sections(in: group)) {
                            section in
                            Label(
                                section.title,
                                systemImage: section.systemImage
                            )
                            .tag(section)
                        }
                    }
                }
            }
            .navigationTitle("LlamaDock")
            .navigationSplitViewColumnWidth(
                min: LlamaDockLayout.sidebarMinWidth,
                ideal: LlamaDockLayout.sidebarIdealWidth,
                max: LlamaDockLayout.sidebarMaxWidth
            )
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detail
                .id(locale.identifier)
        }
        .frame(
            minWidth: 900,
            minHeight: LlamaDockLayout.minimumWindowContentHeight
        )
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
            Text(
                appModel.visibleError
                    ?? appLocalizedString(
                        "An unexpected error occurred.",
                        locale: locale
                    )
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appModel.selectedSection {
        case .overview:
            OverviewView()
        case .service:
            ServersView()
        case .logs:
            LogsView()
        case .runtimes:
            RuntimesView()
        case .models:
            ModelsView()
        case .downloads:
            DownloadsView()
        case nil:
            ContentUnavailableView(
                "Choose a Section",
                systemImage: "sidebar.left",
                description: Text("Select a destination from the sidebar.")
            )
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                StatusBadge(
                    title: appModel.serviceStatus.localizedTitle,
                    systemImage: appModel.serviceStatus.systemImage,
                    tone: appModel.serviceStatus.tone
                )
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gear")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: [.command])
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
