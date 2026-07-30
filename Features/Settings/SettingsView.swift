import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale
    @AppStorage("automaticallyCheckRuntimeUpdates")
    private var automaticallyCheckRuntimeUpdates = true
    @AppStorage("automaticallyCheckAppUpdates")
    private var automaticallyCheckAppUpdates = true
    @AppStorage(AppLanguage.storageKey)
    private var appLanguage = AppLanguage.system
    @AppStorage(AppAppearance.showMenuBarIconKey)
    private var showMenuBarIcon = true
    @AppStorage(AppAppearance.showDockIconKey)
    private var showDockIcon = true
    @State private var huggingFaceToken = ""
    @State private var diagnosticsCopied = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            appearanceSettings
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            updateSettings
                .tabItem {
                    Label(
                        "Updates",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

            huggingFaceSettings
                .tabItem {
                    Label("Hugging Face", systemImage: "globe")
                }

            diagnosticsSettings
                .tabItem {
                    Label(
                        "Diagnostics",
                        systemImage: "stethoscope"
                    )
                }

            aboutSettings
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 620, height: 460)
        .task {
            appModel.refreshHuggingFaceTokenState()
            applyDockAppearance()
        }
    }

    private var generalSettings: some View {
        settingsForm {
            Section("Language") {
                Picker("App Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }

                Text(
                    "Language changes are applied immediately. Follow System uses English when the system language is not supported."
                )
                .settingsCaption()
            }

            Section("Service Lifecycle") {
                Text(
                    "LlamaDock owns only the llama-server process it starts. Quitting the app stops that process and does not install a background daemon."
                )
                .settingsCaption()
            }
        }
    }

    private var appearanceSettings: some View {
        settingsForm {
            Section("App Presence") {
                Toggle(
                    "Show menu bar icon",
                    isOn: $showMenuBarIcon
                )
                .onChange(of: showMenuBarIcon) {
                    if !showMenuBarIcon && !showDockIcon {
                        showDockIcon = true
                    }
                    applyDockAppearance()
                }

                Toggle(
                    "Show application icon in Dock",
                    isOn: $showDockIcon
                )
                .disabled(!showMenuBarIcon && showDockIcon)
                .onChange(of: showDockIcon) {
                    if !showDockIcon {
                        showMenuBarIcon = true
                    }
                    applyDockAppearance()
                }

                Text(
                    "Keep at least one app entry visible so LlamaDock can always be reopened."
                )
                .settingsCaption()
            }

            Section("Accessibility") {
                Text(
                    "LlamaDock follows macOS Reduce Motion, Increase Contrast, keyboard navigation, and VoiceOver settings."
                )
                .settingsCaption()
            }
        }
    }

    private var updateSettings: some View {
        settingsForm {
            Section("LlamaDock App") {
                Toggle(
                    "Check for LlamaDock updates automatically",
                    isOn: $automaticallyCheckAppUpdates
                )

                LabeledContent(
                    "Installed Version",
                    value: "\(appModel.appVersion) (\(appModel.appBuild))"
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
                            .accessibilityLabel(
                                "Checking for LlamaDock updates"
                            )
                    }

                    if
                        let check = appModel.appUpdateCheck,
                        check.isUpdateAvailable
                    {
                        Link(
                            "Download \(check.release.version)",
                            destination: check.release.releasePageURL
                        )
                    }
                }

                if let check = appModel.appUpdateCheck {
                    Label(
                        check.isUpdateAvailable
                            ? localized(
                                "LlamaDock \(check.release.version) is available."
                            )
                            : localized("LlamaDock is up to date."),
                        systemImage: check.isUpdateAvailable
                            ? "arrow.down.circle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        check.isUpdateAvailable ? .blue : .green
                    )
                }

                if let error = appModel.appUpdateError {
                    InlineNotice(error)
                }

                Text(
                    "LlamaDock app releases come from this project's signed GitHub Releases. This channel never changes the separately managed llama.cpp runtime."
                )
                .settingsCaption()
            }

            Section("llama.cpp Runtime") {
                Toggle(
                    "Check for runtime updates automatically",
                    isOn: $automaticallyCheckRuntimeUpdates
                )
                Text(
                    "Runtime updates are independent from LlamaDock app updates."
                )
                .settingsCaption()
            }
        }
    }

    private var huggingFaceSettings: some View {
        settingsForm {
            Section("Access Token") {
                LabeledContent("Status") {
                    Label(
                        appModel.isHuggingFaceTokenConfigured
                            ? localized("Configured")
                            : localized("Not configured"),
                        systemImage:
                            appModel.isHuggingFaceTokenConfigured
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
                        ? localized("Enter a replacement token")
                        : localized("hf_…"),
                    text: $huggingFaceToken
                )
                .accessibilityLabel("Hugging Face access token")

                HStack {
                    Button(
                        appModel.isHuggingFaceTokenConfigured
                            ? localized("Replace Token")
                            : localized("Save Token")
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
                    .disabled(!appModel.isHuggingFaceTokenConfigured)
                }

                Text(
                    "Stored as a generic password in macOS Keychain. The value is never written to settings, UserDefaults, or logs."
                )
                .settingsCaption()

                if let error = appModel.huggingFaceCredentialError {
                    InlineNotice(error)
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        settingsForm {
            Section("Redacted Diagnostics") {
                Button(
                    diagnosticsCopied
                        ? localized("Diagnostics Copied")
                        : localized("Copy Redacted Diagnostics"),
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
                .settingsCaption()
            }
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityLabel("LlamaDock app icon")

            Text("LlamaDock")
                .font(.title.bold())
            Text(
                "Version \(appModel.appVersion) (\(appModel.appBuild))"
            )
            .foregroundStyle(.secondary)

            Text(
                "A native macOS control plane for transparent, external llama.cpp runtimes and local GGUF models."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding(32)
    }

    private func settingsForm<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .padding()
    }

    private func applyDockAppearance() {
        let policy: NSApplication.ActivationPolicy =
            showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private extension View {
    func settingsCaption() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
