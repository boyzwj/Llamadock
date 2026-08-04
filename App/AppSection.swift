import LlamadockCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case logs
    case benchmark
    case models
    case downloads
    case runtimes
    case settings
    case about

    var id: Self { self }

    var productDestination: ProductDestination {
        ProductDestination(rawValue: rawValue) ?? .overview
    }

    var group: ProductNavigationGroup {
        productDestination.group
    }

    static func sections(
        in group: ProductNavigationGroup
    ) -> [Self] {
        ProductDestination.destinations(in: group)
            .compactMap { Self(rawValue: $0.rawValue) }
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Dashboard"
        case .logs: "Logs"
        case .benchmark: "Benchmark"
        case .models: "Models"
        case .downloads: "Downloads"
        case .runtimes: "Runtime"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .logs: "text.alignleft"
        case .benchmark: "speedometer"
        case .models: "externaldrive"
        case .downloads: "arrow.down.circle"
        case .runtimes: "shippingbox"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }

    static func localizedGroupTitle(
        _ group: ProductNavigationGroup
    ) -> LocalizedStringKey {
        switch group {
        case .run:
            "Run"
        case .resources:
            "Resources"
        }
    }
}
