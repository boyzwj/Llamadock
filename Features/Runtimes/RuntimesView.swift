import SwiftUI

struct RuntimesView: View {
    var body: some View {
        ContentUnavailableView(
            "No Runtimes",
            systemImage: "shippingbox",
            description: Text(
                "Detected, managed, Homebrew, and custom llama.cpp runtimes will appear here."
            )
        )
        .navigationTitle("Runtimes")
        .toolbar {
            Button("Add Runtime", systemImage: "plus") {}
                .disabled(true)
                .help("Runtime discovery arrives in Milestone 1.")
        }
    }
}

#Preview {
    RuntimesView()
        .frame(width: 800, height: 600)
}
