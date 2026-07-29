import SwiftUI

struct ModelsView: View {
    var body: some View {
        ContentUnavailableView(
            "No Models",
            systemImage: "externaldrive",
            description: Text("Imported and downloaded GGUF models will appear here.")
        )
        .navigationTitle("Models")
        .toolbar {
            Button("Add Model", systemImage: "plus") {}
                .disabled(true)
                .help("Model selection arrives in Milestone 1.")
        }
    }
}

#Preview {
    ModelsView()
        .frame(width: 800, height: 600)
}
