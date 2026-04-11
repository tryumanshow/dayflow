import SwiftUI

/// Centralised design tokens for dayflow.
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

// MARK: - Color palette --------------------------------------------------------
//
// One warm accent (dfAccent), one positive (dfDone), and a slate neutral
// scale. No purple, no blue glows, no oversaturated chrome — see
// design-taste-frontend rule 2 (Color Calibration) and rule 7 (AI Tells).

extension Color {
    /// Warm signature accent — used sparingly for highlight, focus, today.
    static let dfAccent = Color(red: 0.97, green: 0.55, blue: 0.20)
    static let dfDone   = Color(red: 0.30, green: 0.78, blue: 0.46)
    static let dfTodo   = Color(red: 0.55, green: 0.58, blue: 0.65)

    /// Off-black canvas, never #000.
    static let dfCanvas = Color(red: 0.06, green: 0.07, blue: 0.085)
    /// Slightly raised surface (cards, side rail).
    static let dfSurface = Color(red: 0.10, green: 0.11, blue: 0.13)
    /// Hairline border for surface separation.
    static let dfHairline = Color.white.opacity(0.06)

    static func status(_ s: TaskStatus) -> Color {
        s == .done ? .dfDone : .dfTodo
    }
}

// MARK: - Card chrome ----------------------------------------------------------

/// Reusable card surface. Used sparingly — design-taste rule 4 says cards
/// should be the exception, not the rule. We give it 1px hairline border
/// and a tinted shadow.
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
/// Tight tracking, small caps, secondary colour.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .default))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

/// Status pill — used in the per-task detail view.
struct StatusPill: View {
    let status: TaskStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.status(status))
                .frame(width: 6, height: 6)
            Text(status == .done ? "DONE" : "TODO")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.status(status))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.status(status).opacity(0.14))
        )
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
