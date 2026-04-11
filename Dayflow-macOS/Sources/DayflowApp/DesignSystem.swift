import SwiftUI

/// Centralised design tokens for dayflow.
///
/// One source of truth so spacing/typography/colour stay coherent across views.
/// Adjust here, not at call sites.
enum DS {
    // 8pt grid
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let pill: CGFloat = 999
    }

    enum Motion {
        static let quick: Animation = .spring(response: 0.25, dampingFraction: 0.85)
        static let smooth: Animation = .easeInOut(duration: 0.18)
    }

    enum FontStyle {
        static let display = Font.system(size: 22, weight: .semibold, design: .default)
        static let title   = Font.system(size: 17, weight: .semibold, design: .default)
        static let body    = Font.system(size: 13, weight: .regular,  design: .default)
        static let caption = Font.system(size: 11, weight: .regular,  design: .default)
        static let micro   = Font.system(size: 10, weight: .regular,  design: .monospaced)
    }
}

extension Color {
    static let dfTodo  = Color(red: 0.32, green: 0.55, blue: 0.95)
    static let dfDoing = Color(red: 0.97, green: 0.62, blue: 0.20)
    static let dfDone  = Color(red: 0.30, green: 0.78, blue: 0.46)
    static let dfWont  = Color(red: 0.55, green: 0.55, blue: 0.58)

    static func status(_ s: TaskStatus) -> Color {
        switch s {
        case .todo:  return .dfTodo
        case .doing: return .dfDoing
        case .done:  return .dfDone
        case .wont:  return .dfWont
        }
    }
}

/// Reusable card chrome.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Space.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

/// Status pill — keeps colour usage consistent.
struct StatusPill: View {
    let status: TaskStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.status(status))
                .frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.status(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.status(status).opacity(0.12))
        )
    }
}

/// Empty-state placeholder. Friendly tone, single source of truth.
struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            Text(icon).font(.system(size: 32))
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
    let ratio: Double  // 0...1
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
