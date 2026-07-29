import SwiftUI

struct ServersView: View {
    var body: some View {
        ContentUnavailableView(
            "Server Stopped",
            systemImage: "server.rack",
            description: Text("Choose a runtime, model, and profile to start llama-server.")
        )
        .navigationTitle("Servers")
        .toolbar {
            Button("Start", systemImage: "play.fill") {}
                .disabled(true)
                .help("Server process management arrives in Milestone 1.")
        }
    }
}

#Preview {
    ServersView()
        .frame(width: 800, height: 600)
}
