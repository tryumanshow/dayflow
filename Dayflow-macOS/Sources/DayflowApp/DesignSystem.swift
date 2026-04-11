import SwiftUI

/// Centralised design tokens for Dayflow.
///
/// Calibrated from the design-taste-frontend skill (DESIGN_VARIANCE 8 /
/// MOTION_INTENSITY 6 / VISUAL_DENSITY 4) — anti-emoji, single accent,
/// off-black background, restrained spacing rhythm, spring physics.
enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
        static let huge: CGFloat = 56
        /// Extra breathing room above primary focal elements (display titles,
        /// metric numbers). Used where `xl` felt cramped against chrome.
        static let breathe: CGFloat = 44
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 28
        static let pill: CGFloat = 999
    }

    enum Motion {
        static let snap: Animation = .interactiveSpring(response: 0.18, dampingFraction: 0.86, blendDuration: 0.1)
        static let quick: Animation = .spring(response: 0.28, dampingFraction: 0.84)
        static let smooth: Animation = .easeInOut(duration: 0.22)
        /// View transitions (Day ↔ Week ↔ Month). Spring physics read as
        /// "look at me", which is wrong for navigation. A soft ease-out lets
        /// the transition happen without drawing attention.
        static let settle: Animation = .easeOut(duration: 0.15)
    }

    enum FontStyle {
        static let display = Font.system(size: 28, weight: .bold, design: .default)
        static let title   = Font.system(size: 17, weight: .semibold, design: .default)
        static let subhead = Font.system(size: 13, weight: .semibold, design: .default)
        static let body    = Font.system(size: 13, weight: .regular,  design: .default)
        static let caption = Font.system(size: 11, weight: .regular,  design: .default)
        static let micro   = Font.system(size: 10, weight: .medium,   design: .monospaced)
        static let metric  = Font.system(size: 36, weight: .bold,     design: .default).monospacedDigit()
    }
}

// MARK: - Date formatters ------------------------------------------------------

/// Cached `DateFormatter` instances. `DateFormatter()` init is expensive;
/// the week view alone hits format helpers 14+ times per render, the month
/// view 42+ times. Hoisting these into `static let` turns render-time
/// allocations into property lookups.
enum DF {
    /// POSIX, fixed — used for DB keys so they're stable regardless of the
    /// user's current locale.
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let isoTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// POSIX, fixed — used as the `month_plans` primary key.
    static let monthKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    /// POSIX, fixed — used as the `appointments.start_at` storage
    /// format. Wall-clock local time, minute precision.
    static let appointmentStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// POSIX, fixed — just the HH:mm slice of an appointment start
    /// time. Used both for display in the preview columns and for
    /// parsing user input in the Day rail add form.
    static let hourMinute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayNumber: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    // Locale-aware formatters — these follow whatever language macOS /
    // the Dayflow language override currently resolves to. They read
    // `Locale.current` so the first access after a language change picks
    // up the new locale on the next relaunch.

    static var weekday: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("E")
        return f
    }

    static var monthTitle: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }

    static var fullDate: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        return f
    }

    static var shortDate: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return f
    }

    static var shortMonthDay: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }
}

// MARK: - Markdown line parsing ------------------------------------------------

/// Classifies a single trimmed markdown line. BlockNote's
/// `blocksToMarkdownLossy` emits `*   [x] foo` (multi-space after the
/// bullet), which is still valid CommonMark — all parsing sites need to
/// tolerate that, so we centralise the rule here.
enum MarkdownLine {
    case heading(level: Int, text: String)
    case task(checked: Bool, text: String)
    case bullet(text: String)
    case plain(text: String)

    /// Parse a single trimmed line. Returns `nil` only when the line is
    /// empty; every other input yields one of the four cases.
    static func parse(_ rawTrimmed: String) -> MarkdownLine? {
        let trimmed = rawTrimmed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("### ") { return .heading(level: 3, text: String(trimmed.dropFirst(4))) }
        if trimmed.hasPrefix("## ")  { return .heading(level: 2, text: String(trimmed.dropFirst(3))) }
        if trimmed.hasPrefix("# ")   { return .heading(level: 1, text: String(trimmed.dropFirst(2))) }

        guard let first = trimmed.first, first == "-" || first == "*" || first == "+" else {
            return .plain(text: trimmed)
        }
        var rest = trimmed.dropFirst()
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })

        if rest.hasPrefix("["), rest.count >= 3 {
            let inside = rest.dropFirst()
            if let mark = inside.first {
                let close = inside.index(after: inside.startIndex)
                if inside[close] == "]" {
                    var after = inside.dropFirst(2)
                    after = after.drop(while: { $0 == " " || $0 == "\t" })
                    switch mark {
                    case " ":
                        return .task(checked: false, text: String(after))
                    case "x", "X", "✓":
                        return .task(checked: true,  text: String(after))
                    default: break
                    }
                }
            }
        }
        return .bullet(text: String(rest))
    }
}

// MARK: - Color palette --------------------------------------------------------

extension Color {
    /// Warm signature accent — used sparingly for highlight, focus, today.
    static let dfAccent = Color(red: 0.97, green: 0.55, blue: 0.20)
    static let dfDone   = Color(red: 0.30, green: 0.78, blue: 0.46)
    static let dfTodo   = Color(red: 0.55, green: 0.58, blue: 0.65)

    /// Off-black canvas, never #000.
    static let dfCanvas = Color(red: 0.06, green: 0.07, blue: 0.085)
    /// Slightly raised surface (cards, side rail).
    static let dfSurface = Color(red: 0.10, green: 0.11, blue: 0.13)
    /// Quiet panel — 2% brighter than canvas, used for side rails so the
    /// divide reads even without a border. Replaces `dfSurface.opacity(0.4)`.
    static let dfQuiet = Color(red: 0.08, green: 0.09, blue: 0.105)
    /// Hairline border for surface separation.
    static let dfHairline = Color.white.opacity(0.06)
    /// Even softer hairline for repeated structures (grid cells) where the
    /// standard hairline accumulates into visual noise.
    static let dfHairlineSoft = Color.white.opacity(0.035)
}

// MARK: - Card chrome ----------------------------------------------------------

/// Reusable card surface. Used sparingly — design-taste rule 4 says cards
/// should be the exception, not the rule.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Space.lg
    var background: Color = .dfSurface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .stroke(Color.dfHairline, lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
    }
}

/// Section header — used for grouping things without resorting to nested cards.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .default))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

/// Empty-state placeholder — uses an SF Symbol, never an emoji.
struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(DS.FontStyle.title)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compact brand mark — mirrors the app icon (warm 3/4 arc around a bold D).
/// Used in the navigation bar so the nav logo and Dock icon read as the same
/// thing. Sized parametrically so the same view covers 14pt nav usage and
/// larger hero surfaces.
struct DayflowLogo: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    Color.dfAccent,
                    style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("D")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.015)
        }
        .frame(width: size, height: size)
    }
}

/// Donut progress ring used in the month grid cells.
struct CompletionRing: View {
    let ratio: Double
    let lineWidth: CGFloat
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, ratio))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.quick, value: ratio)
        }
        .frame(width: size, height: size)
    }
}
