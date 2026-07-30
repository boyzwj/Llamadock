import LlamadockCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case service
    case logs
    case models
    case downloads
    case runtimes

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
        case .overview: "Overview"
        case .service: "Service"
        case .logs: "Logs"
        case .models: "Models"
        case .downloads: "Downloads"
        case .runtimes: "Runtime"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .service: "server.rack"
        case .logs: "text.alignleft"
        case .models: "externaldrive"
        case .downloads: "arrow.down.circle"
        case .runtimes: "shippingbox"
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
