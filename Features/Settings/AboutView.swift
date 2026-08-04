import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale

    private let projectLinks = [
        AboutLink(
            title: "GitHub",
            detail: "Source code and project",
            systemImage: "chevron.left.forwardslash.chevron.right",
            url: URL(string: "https://github.com/boyzwj/Llamadock")!
        ),
        AboutLink(
            title: "Releases",
            detail: "Version history and downloads",
            systemImage: "shippingbox",
            url: URL(
                string: "https://github.com/boyzwj/Llamadock/releases"
            )!
        ),
        AboutLink(
            title: "Documentation",
            detail: "Setup and usage guide",
            systemImage: "book.closed",
            url: URL(
                string: "https://github.com/boyzwj/Llamadock#readme"
            )!
        ),
        AboutLink(
            title: "Report an Issue",
            detail: "Bugs and feature requests",
            systemImage: "ladybug",
            url: URL(
                string: "https://github.com/boyzwj/Llamadock/issues"
            )!
        ),
    ]

    private let foundationLinks = [
        AboutLink(
            title: "llama.cpp",
            detail: "Local inference runtime and server",
            systemImage: "server.rack",
            url: URL(string: "https://github.com/ggml-org/llama.cpp")!
        ),
        AboutLink(
            title: "GGUF",
            detail: "Portable model file format",
            systemImage: "doc.zipper",
            url: URL(
                string:
                    "https://github.com/ggml-org/ggml/blob/master/docs/gguf.md"
            )!
        ),
        AboutLink(
            title: "SwiftUI",
            detail: "Native macOS interface",
            systemImage: "swift",
            url: URL(
                string: "https://developer.apple.com/xcode/swiftui/"
            )!
        ),
    ]

    var body: some View {
        LlamaDockPage {
            LlamaDockPageHeader(
                "About LlamaDock",
                subtitle: "Project, version, license, and runtime information."
            )

            hero
            linksSection
            licenseSection
            foundationsSection
            systemSection
        }
        .navigationTitle("About")
    }

    private var hero: some View {
        SectionCard {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104, height: 104)
                    .accessibilityLabel("LlamaDock app icon")

                Text("LlamaDock")
                    .font(.largeTitle.bold())

                Text(
                    "Native multi-model control for llama.cpp on macOS"
                )
                .font(.title3)
                .foregroundStyle(.secondary)

                Text(
                    "Version \(appModel.appVersion) (\(appModel.appBuild))"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

                Text(
                    "Browse local GGUF models, manage llama-server configurations, run multiple routed models, and measure real inference throughput from one native app."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 660)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project")
                .font(.title2.bold())

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 220), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(projectLinks) { link in
                    linkCard(link)
                }
            }
        }
    }

    private var licenseSection: some View {
        SectionCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "checkmark.seal")
                    .font(.title)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 7) {
                    Text("MIT License")
                        .font(.title3.bold())
                    Text(
                        "LlamaDock is open-source software. Copyright © LlamaDock contributors."
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        "The MIT License permits use, copying, modification, distribution, and private or commercial use subject to its copyright and license notice."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Link(
                    "View License",
                    destination: URL(
                        string:
                            "https://github.com/boyzwj/Llamadock/blob/main/LICENSE"
                    )!
                )
            }
        }
    }

    private var foundationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built On")
                .font(.title2.bold())

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 220), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(foundationLinks) { link in
                    linkCard(link)
                }
            }
        }
    }

    private var systemSection: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Current Environment", systemImage: "desktopcomputer")
                    .font(.title3.bold())

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 22,
                    verticalSpacing: 10
                ) {
                    environmentRow(
                        "System",
                        ProcessInfo.processInfo.operatingSystemVersionString
                    )
                    environmentRow("Architecture", architecture)
                    environmentRow(
                        "Hardware",
                        localized(
                            "\(ProcessInfo.processInfo.processorCount) CPU cores • \(formattedMemory) memory"
                        )
                    )
                    environmentRow("Runtime", runtimeSummary)
                    environmentRow(
                        "Enabled Models",
                        String(appModel.enabledRouterProfiles.count)
                    )
                }
            }
        }
    }

    private func linkCard(_ item: AboutLink) -> some View {
        Link(destination: item.url) {
            SectionCard {
                HStack(spacing: 13) {
                    Image(systemName: item.systemImage)
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(item.title))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(LocalizedStringKey(item.detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func environmentRow(
        _ title: LocalizedStringKey,
        _ value: String
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var runtimeSummary: String {
        guard let runtime = appModel.selectedRuntime else {
            return localized("Not configured")
        }
        return runtime.versionOutput
            .split(separator: "\n")
            .first
            .map(String.init)
            ?? runtime.source.rawValue
    }

    private var formattedMemory: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(
                min(
                    ProcessInfo.processInfo.physicalMemory,
                    UInt64(Int64.max)
                )
            ),
            countStyle: .memory
        )
    }

    private var architecture: String {
        #if arch(arm64)
        localized("Apple silicon (arm64)")
        #elseif arch(x86_64)
        localized("Intel (x86_64)")
        #else
        localized("Unknown")
        #endif
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

private struct AboutLink: Identifiable {
    let title: String
    let detail: String
    let systemImage: String
    let url: URL

    var id: String {
        url.absoluteString
    }
}

#Preview {
    AboutView()
        .environment(AppModel())
}
