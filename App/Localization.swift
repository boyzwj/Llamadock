import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"

    case system
    case english
    case simplifiedChinese

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system:
            "Follow System"
        case .english:
            "English"
        case .simplifiedChinese:
            "Simplified Chinese"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            .autoupdatingCurrent
        case .english:
            Locale(identifier: "en")
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        }
    }
}

func appLocalizedString(
    _ value: String.LocalizationValue,
    locale: Locale
) -> String {
    let resourceName =
        locale.identifier.lowercased().hasPrefix("zh")
            ? "zh-Hans"
            : "en"
    guard
        let path = Bundle.main.path(
            forResource: resourceName,
            ofType: "lproj"
        ),
        let languageBundle = Bundle(path: path)
    else {
        return String(localized: value, locale: locale)
    }
    return String(
        localized: value,
        bundle: languageBundle,
        locale: locale
    )
}
