import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("automaticallyCheckRuntimeUpdates")
    private var automaticallyCheckRuntimeUpdates = true
    @State private var huggingFaceToken = ""

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

            Section("Hugging Face") {
                LabeledContent("Access Token") {
                    Label(
                        appModel.isHuggingFaceTokenConfigured
                            ? "Configured"
                            : "Not configured",
                        systemImage: appModel
                            .isHuggingFaceTokenConfigured
                            ? "checkmark.shield.fill"
                            : "lock"
                    )
                    .foregroundStyle(
                        appModel.isHuggingFaceTokenConfigured
                            ? .green
                            : .secondary
                    )
                }

                SecureField(
                    appModel.isHuggingFaceTokenConfigured
                        ? "Enter a replacement token"
                        : "hf_…",
                    text: $huggingFaceToken
                )

                HStack {
                    Button(
                        appModel.isHuggingFaceTokenConfigured
                            ? "Replace Token"
                            : "Save Token"
                    ) {
                        if appModel.saveHuggingFaceToken(
                            huggingFaceToken
                        ) {
                            huggingFaceToken = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(huggingFaceToken.isEmpty)

                    Button(
                        "Remove Token",
                        role: .destructive
                    ) {
                        appModel.deleteHuggingFaceToken()
                        huggingFaceToken = ""
                    }
                    .disabled(
                        !appModel.isHuggingFaceTokenConfigured
                    )
                }

                Text(
                    "Stored as a generic password in macOS Keychain. The value is never written to settings, UserDefaults, or logs."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let error = appModel.huggingFaceCredentialError {
                    Label(
                        error,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }
            }

            Section("About") {
                LabeledContent("Product", value: "LlamaDock")
                LabeledContent("Version", value: "0.1.0")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .task {
            appModel.refreshHuggingFaceTokenState()
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
