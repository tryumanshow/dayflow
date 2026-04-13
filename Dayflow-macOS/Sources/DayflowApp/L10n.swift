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

/// `UserDefaults` / `@AppStorage` keys that are referenced from
/// more than one file. Co-located with their defaults so a typo in
/// either consumer can't silently split state into two buckets.
enum AppStorageKeys {
    static let dayEditorFontSize       = "dayflow.editor.fontSize"
    static let monthPlanEditorFontSize = "dayflow.editor.fontSize.monthPlan"
    /// Default `.off` (enforced at each `@AppStorage` call site) —
    /// holidays are opt-in so first-launch users see the calendar
    /// clean until they ask for KR/US markers.
    static let holidaysMode            = "dayflow.holidays.mode"

    static let dayEditorFontSizeDefault: Double       = 15
    static let monthPlanEditorFontSizeDefault: Double = 13
    static let startDate                       = "dayflow.startDate"
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
    /// The language code (`en` / `ko`) we resolved at startup by
    /// intersecting `AppleLanguages` with the available `.lproj`s.
    static let activeLanguageCode: String = {
        let available = Bundle.module.localizations
        let userPrefs = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
            ?? Locale.preferredLanguages
        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: userPrefs)
        return preferred.first ?? "en"
    }()

    static let activeBundle: Bundle = {
        if let path = Bundle.module.path(forResource: activeLanguageCode, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return Bundle.module
    }()

    /// Locale built from the active language. Use this for
    /// `DateFormatter.locale` so the app's language override drives
    /// weekday / month / date display — `Locale.current` alone would
    /// still follow the OS system locale, leaving the nav bar date
    /// stuck in English when the app runs in Korean.
    static let activeLocale: Locale = Locale(identifier: activeLanguageCode)
}

func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: DayflowL10n.activeBundle, value: key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let template = NSLocalizedString(key, tableName: nil, bundle: DayflowL10n.activeBundle, value: key, comment: "")
    return String(format: template, locale: Locale.current, arguments: arguments)
}
