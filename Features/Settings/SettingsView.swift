import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("automaticallyCheckRuntimeUpdates")
    private var automaticallyCheckRuntimeUpdates = true
    @AppStorage("automaticallyCheckAppUpdates")
    private var automaticallyCheckAppUpdates = true
    @State private var huggingFaceToken = ""
    @State private var diagnosticsCopied = false

    var body: some View {
        Form {
            Section("LlamaDock App") {
                Toggle(
                    "Check for LlamaDock updates automatically",
                    isOn: $automaticallyCheckAppUpdates
                )

                LabeledContent(
                    "Installed Version",
                    value:
                        "\(appModel.appVersion) (\(appModel.appBuild))"
                )

                HStack {
                    Button(
                        "Check for LlamaDock Update",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        Task {
                            await appModel.checkAppUpdates()
                        }
                    }
                    .disabled(appModel.isCheckingAppUpdates)

                    if appModel.isCheckingAppUpdates {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if
                        let check = appModel.appUpdateCheck,
                        check.isUpdateAvailable
                    {
                        Link(
                            "Download \(check.release.version)",
                            destination:
                                check.release.releasePageURL
                        )
                    }
                }

                if let check = appModel.appUpdateCheck {
                    Label(
                        check.isUpdateAvailable
                            ? "LlamaDock \(check.release.version) is available."
                            : "LlamaDock is up to date.",
                        systemImage: check.isUpdateAvailable
                            ? "arrow.down.circle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        check.isUpdateAvailable
                            ? .blue
                            : .green
                    )
                }

                if let error = appModel.appUpdateError {
                    Label(
                        error,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }

                Text(
                    "LlamaDock app releases come from this project's signed GitHub Releases. This channel never changes the separately managed llama.cpp runtime."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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

            Section("Diagnostics") {
                Button(
                    diagnosticsCopied
                        ? "Diagnostics Copied"
                        : "Copy Redacted Diagnostics",
                    systemImage: diagnosticsCopied
                        ? "checkmark"
                        : "doc.on.doc"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        appModel.makeDiagnosticsReport(),
                        forType: .string
                    )
                    diagnosticsCopied = true
                }

                Text(
                    "Includes versions, hardware, runtime/model/profile/download summaries, server state, and update status. Credentials, signed URL queries, prompts, launch arguments, and server log contents are excluded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Product", value: "LlamaDock")
                LabeledContent(
                    "Version",
                    value:
                        "\(appModel.appVersion) (\(appModel.appBuild))"
                )
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
