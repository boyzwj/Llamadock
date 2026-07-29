import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case runtimes
    case models
    case servers

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .runtimes: "Runtimes"
        case .models: "Models"
        case .servers: "Servers"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .runtimes: "shippingbox"
        case .models: "externaldrive"
        case .servers: "server.rack"
        }
    }
}
