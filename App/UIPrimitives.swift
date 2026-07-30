import LlamadockCore
import SwiftUI

enum LlamaDockLayout {
    static let pagePadding: CGFloat = 26
    static let sectionSpacing: CGFloat = 22
    static let cardPadding: CGFloat = 18
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 232
    static let sidebarMaxWidth: CGFloat = 248
    // The unified title bar adds about 52 pt to the NSWindow frame.
    static let minimumWindowContentHeight: CGFloat = 548
}

enum LlamaDockStatusTone {
    case ready
    case active
    case degraded
    case failed
    case stopped

    var color: Color {
        switch self {
        case .ready:
            .green
        case .active:
            .blue
        case .degraded:
            .orange
        case .failed:
            .red
        case .stopped:
            .secondary
        }
    }
}

extension ServiceStatusKind {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .ready:
            "Ready"
        case .degraded:
            "Degraded"
        case .failed:
            "Failed"
        case .stopping:
            "Stopping"
        }
    }

    var systemImage: String {
        switch self {
        case .stopped:
            "stop.circle"
        case .starting, .stopping:
            "clock.arrow.circlepath"
        case .ready:
            "checkmark.circle.fill"
        case .degraded:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.circle.fill"
        }
    }

    var tone: LlamaDockStatusTone {
        switch self {
        case .stopped:
            .stopped
        case .starting, .stopping:
            .active
        case .ready:
            .ready
        case .degraded:
            .degraded
        case .failed:
            .failed
        }
    }

    var menuBarSystemImage: String {
        switch self {
        case .stopped:
            "server.rack"
        case .starting, .stopping:
            "arrow.triangle.2.circlepath"
        case .ready:
            "server.rack"
        case .degraded:
            "exclamationmark.triangle"
        case .failed:
            "xmark.circle"
        }
    }

    func localizedString(locale: Locale) -> String {
        switch self {
        case .stopped:
            appLocalizedString("Stopped", locale: locale)
        case .starting:
            appLocalizedString("Starting", locale: locale)
        case .ready:
            appLocalizedString("Ready", locale: locale)
        case .degraded:
            appLocalizedString("Degraded", locale: locale)
        case .failed:
            appLocalizedString("Failed", locale: locale)
        case .stopping:
            appLocalizedString("Stopping", locale: locale)
        }
    }
}

struct LlamaDockPage<Content: View>: View {
    let content: Content

    init(
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: LlamaDockLayout.sectionSpacing
            ) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LlamaDockLayout.pagePadding)
        }
    }
}

struct LlamaDockPageHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let actions: Actions

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.largeTitle.bold())
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)
            actions
        }
    }
}

extension LlamaDockPageHeader where Actions == EmptyView {
    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil
    ) {
        self.init(title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct SectionCard<Content: View>: View {
    let content: Content

    init(
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LlamaDockLayout.cardPadding)
            .background(
                .background.secondary,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
    }
}

struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    var tone: LlamaDockStatusTone = .stopped

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ServiceHeroCard: View {
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.locale) private var locale
    let status: ServiceStatusKind
    let detail: String
    let runtime: String
    let endpoint: String?
    let isOperationInProgress: Bool
    let canStart: Bool
    let canStop: Bool
    let canRestart: Bool
    let startHelp: String?
    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void

    var body: some View {
        SectionCard {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(status.tone.color)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive:
                            !reduceMotion
                                && (
                                    status == .starting
                                        || status == .stopping
                                )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Text(status.localizedTitle)
                            .font(.title2.bold())
                        StatusBadge(
                            title: status.localizedTitle,
                            systemImage: status.systemImage,
                            tone: status.tone
                        )
                    }

                    Text(detail)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Label(runtime, systemImage: "shippingbox")
                        if let endpoint {
                            Label(endpoint, systemImage: "network")
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 9) {
                    if isOperationInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                "Server operation in progress"
                            )
                    }

                    HStack(spacing: 8) {
                        if canStart || !canStop {
                            Button(
                                "Start",
                                systemImage: "play.fill",
                                action: start
                            )
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStart)
                            .help(
                                startHelp
                                    ?? appLocalizedString(
                                        "Start the selected launch profile.",
                                        locale: locale
                                    )
                            )
                        } else {
                            Button(
                                "Stop",
                                systemImage: "stop.fill",
                                action: stop
                            )
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStop)
                        }

                        Button(
                            "Restart",
                            systemImage: "arrow.clockwise",
                            action: restart
                        )
                        .disabled(!canRestart)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Owned server status")
        }
    }
}

struct StatusBadge: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tone: LlamaDockStatusTone

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                tone.color.opacity(0.12),
                in: Capsule()
            )
            .accessibilityElement(children: .combine)
    }
}

struct InlineNotice<Actions: View>: View {
    let title: String
    let systemImage: String
    let tone: LlamaDockStatusTone
    let actions: Actions

    init(
        _ title: String,
        systemImage: String = "exclamationmark.triangle.fill",
        tone: LlamaDockStatusTone = .degraded,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            actions
        }
        .padding(12)
        .background(
            tone.color.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain)
    }
}

extension InlineNotice where Actions == EmptyView {
    init(
        _ title: String,
        systemImage: String = "exclamationmark.triangle.fill",
        tone: LlamaDockStatusTone = .degraded
    ) {
        self.init(
            title,
            systemImage: systemImage,
            tone: tone
        ) {
            EmptyView()
        }
    }
}

struct EmptyStateAction: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let systemImage: String
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

#Preview("Primitives") {
    LlamaDockPage {
        LlamaDockPageHeader(
            "Overview",
            subtitle: "Local llama.cpp service control"
        )
        SectionCard {
            HStack {
                StatusBadge(
                    title: "Ready",
                    systemImage: "checkmark.circle.fill",
                    tone: .ready
                )
                Spacer()
                Button("Stop") {}
            }
        }
        InlineNotice("Example recoverable service notice")
    }
    .frame(width: 900, height: 600)
}
