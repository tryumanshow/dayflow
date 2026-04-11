import Foundation
import SwiftUI

/// Language override stored in UserDefaults. `nil` means "follow the macOS
/// system language". Otherwise the raw code (`en`, `ko`) wins at app start.
///
/// macOS reads `AppleLanguages` out of the app's UserDefaults very early in
/// launch. Writing to it after the app is up doesn't retro-fit already-loaded
/// `Bundle.main`, so a language change requires a relaunch — the Settings UI
/// surfaces that hint explicitly.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ko

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "language.system_default", bundle: .module)
        case .en:     return String(localized: "language.english", bundle: .module)
        case .ko:     return String(localized: "language.korean", bundle: .module)
        }
    }
}

enum LanguagePreference {
    private static let key = "dayflow.language"

    static var current: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let lang = AppLanguage(rawValue: raw) {
                return lang
            }
            return .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            switch newValue {
            case .system:
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .en:
                UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            case .ko:
                UserDefaults.standard.set(["ko"], forKey: "AppleLanguages")
            }
        }
    }

    /// Called at startup (before the first SwiftUI body runs) so the very
    /// first `Bundle.main` / `Bundle.module` resolution sees the override.
    static func applyAtStartup() {
        switch current {
        case .system:
            break
        case .en:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .ko:
            UserDefaults.standard.set(["ko"], forKey: "AppleLanguages")
        }
    }
}

/// Picks the right `<lang>.lproj` subbundle inside the SwiftPM resource
/// bundle, honoring the app's `AppleLanguages` override.
///
/// `Bundle.module` alone doesn't do this: its `preferredLocalizations`
/// property is computed at bundle-load time against the resource bundle's
/// own development region, and it ignores later writes to the parent app's
/// `AppleLanguages`. So we compute the preferred language ourselves and
/// open the specific `lproj` sub-bundle as its own `Bundle`.
enum DayflowL10n {
    static let activeBundle: Bundle = {
        let available = Bundle.module.localizations
        let userPrefs = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
            ?? Locale.preferredLanguages
        let preferred = Bundle.preferredLocalizations(
            from: available,
            forPreferences: userPrefs
        )
        if let code = preferred.first,
           let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return Bundle.module
    }()
}

func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: DayflowL10n.activeBundle, value: key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let template = NSLocalizedString(key, tableName: nil, bundle: DayflowL10n.activeBundle, value: key, comment: "")
    return String(format: template, locale: Locale.current, arguments: arguments)
}
