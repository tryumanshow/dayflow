import AppKit
import Observation
import SwiftUI

/// Background palettes the user can pick in Settings → Appearance.
///
/// A theme sets the three surface colours (`dfCanvas` / `dfQuiet` /
/// `dfSurface`) and whether the app runs in dark or light appearance. Text
/// and hairlines use `.primary`, which follows that appearance, so a light
/// palette needs no per-view colour switches. The editor web view gets the
/// same palette as two CSS variables (see `editorInk` / `editorPanel`).
enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case graphite
    case navy
    case paper
    case sepia

    var id: String { rawValue }

    var isDark: Bool {
        switch self {
        case .midnight, .graphite, .navy: true
        case .paper, .sepia: false
        }
    }

    var label: String { L("theme.\(rawValue)") }

    /// Window background.
    var canvas: Color {
        switch self {
        case .midnight: Color(red: 0.06, green: 0.07, blue: 0.085)
        case .graphite: Color(red: 0.12, green: 0.12, blue: 0.13)
        case .navy:     Color(red: 0.05, green: 0.08, blue: 0.14)
        case .paper:    Color(red: 0.985, green: 0.98, blue: 0.97)
        case .sepia:    Color(red: 0.96, green: 0.93, blue: 0.87)
        }
    }

    /// Side rails: a step off the canvas so the divide reads without a border.
    var quiet: Color {
        switch self {
        case .midnight: Color(red: 0.08, green: 0.09, blue: 0.105)
        case .graphite: Color(red: 0.14, green: 0.14, blue: 0.15)
        case .navy:     Color(red: 0.065, green: 0.10, blue: 0.17)
        case .paper:    Color(red: 0.955, green: 0.95, blue: 0.94)
        case .sepia:    Color(red: 0.93, green: 0.90, blue: 0.83)
        }
    }

    /// Raised surfaces (cards).
    var surface: Color {
        switch self {
        case .midnight: Color(red: 0.10, green: 0.11, blue: 0.13)
        case .graphite: Color(red: 0.17, green: 0.17, blue: 0.18)
        case .navy:     Color(red: 0.08, green: 0.12, blue: 0.20)
        case .paper:    Color(red: 1.0, green: 1.0, blue: 1.0)
        case .sepia:    Color(red: 0.98, green: 0.96, blue: 0.91)
        }
    }

    /// Editor text / line colour as an `r, g, b` triple for CSS `rgba()`.
    var editorInk: String {
        switch self {
        case .midnight, .graphite, .navy: "255, 255, 255"
        case .paper: "24, 26, 32"
        case .sepia: "62, 46, 30"
        }
    }

    /// Editor popover / toolbar panel colour, `r, g, b`.
    var editorPanel: String {
        switch self {
        case .midnight: "28, 28, 32"
        case .graphite: "42, 42, 46"
        case .navy:     "22, 33, 54"
        case .paper:    "250, 249, 246"
        case .sepia:    "246, 239, 225"
        }
    }
}

/// The selected theme, persisted in UserDefaults. `@Observable` so any view
/// whose body reads a themed colour (through `Color.dfCanvas` and friends)
/// re-renders when it changes — no environment plumbing through every view.
@Observable
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()
    static let defaultsKey = "dayflow.theme"

    var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
            Task { @MainActor in
                Self.applyAppearance(self.theme)
                NotificationCenter.default.post(name: .dayflowThemeChanged, object: nil)
            }
        }
    }

    private init() {
        theme = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppTheme.init(rawValue:)) ?? .midnight
    }

    /// Pin the whole app (every window, sheet and panel) to the theme's
    /// appearance, so `.primary` text and system controls match the palette
    /// instead of following the macOS-wide setting.
    @MainActor
    static func applyAppearance(_ theme: AppTheme) {
        NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }
}

extension Notification.Name {
    /// Posted after the theme changes; editor web views restyle themselves.
    static let dayflowThemeChanged = Notification.Name("dayflowThemeChanged")
}
