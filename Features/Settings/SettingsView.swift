import SwiftUI

struct SettingsView: View {
    @AppStorage("automaticallyCheckRuntimeUpdates")
    private var automaticallyCheckRuntimeUpdates = true

    var body: some View {
        Form {
            Section("llama.cpp Runtime") {
                Toggle(
                    "Check for runtime updates automatically",
                    isOn: $automaticallyCheckRuntimeUpdates
                )
                Text("Runtime updates are independent from LlamaDock app updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Product", value: "LlamaDock")
                LabeledContent("Version", value: "0.1.0")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

#Preview {
    SettingsView()
}
