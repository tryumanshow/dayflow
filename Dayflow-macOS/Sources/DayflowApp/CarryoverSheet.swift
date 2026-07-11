import SwiftUI

/// Thin prompt above the Day editor: "N unfinished tasks are still sitting on
/// earlier days." Only appears on today, only when there's something to carry,
/// and only until the user acts on it or dismisses it for the day.
@MainActor
struct CarryoverBanner: View {
    let count: Int
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.uturn.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dfAccent)
            Text(L("carryover.banner", count))
                .font(DS.FontStyle.body)
                .foregroundStyle(.primary)
            Spacer(minLength: DS.Space.sm)
            Button(action: onReview) {
                Text(L("carryover.review"))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.dfAccent.opacity(0.16)))
                    .foregroundStyle(Color.dfAccent)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L("carryover.dismiss"))
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(Color.dfAccent.opacity(0.07))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dfHairline).frame(height: 0.7)
        }
    }
}

/// The batch handed to the sheet. Exists so the sheet can be presented with
/// `.sheet(item:)`: the `isPresented` form evaluates its content against the
/// view as it was *before* the same-transaction write to the items array, and
/// came up with an empty list every time.
struct CarryoverBatch: Identifiable {
    let id = UUID()
    let items: [CarryoverItem]
}

/// Per-item confirmation for the carry-over. Carrying MOVES a task — the
/// checkbox is deleted from the day it was written on — so nothing happens
/// without the user seeing the exact list and pressing the button.
@MainActor
struct CarryoverSheet: View {
    let items: [CarryoverItem]
    let onCarry: ([CarryoverItem]) -> Void
    let onCancel: () -> Void

    /// Everything starts selected — the common case is "yes, all of it".
    @State private var selected: Set<String>

    init(items: [CarryoverItem],
         onCarry: @escaping ([CarryoverItem]) -> Void,
         onCancel: @escaping () -> Void) {
        self.items = items
        self.onCarry = onCarry
        self.onCancel = onCancel
        _selected = State(initialValue: Set(items.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("carryover.title"))
                    .font(.headline)
                Text(L("carryover.hint"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Button(L("carryover.select_all")) {
                    selected = Set(items.map(\.id))
                }
                .buttonStyle(.plain)
                .font(DS.FontStyle.caption)
                .foregroundStyle(Color.dfAccent)
                .disabled(selected.count == items.count)

                Button(L("carryover.select_none")) {
                    selected = []
                }
                .buttonStyle(.plain)
                .font(DS.FontStyle.caption)
                .foregroundStyle(Color.dfAccent)
                .disabled(selected.isEmpty)

                Spacer()

                Button(L("appointments.cancel")) { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L("carryover.confirm", selected.count)) {
                    onCarry(items.filter { selected.contains($0.id) })
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(_ item: CarryoverItem) -> some View {
        let isOn = selected.contains(item.id)
        return Button {
            if isOn { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Color.dfAccent : Color.secondary)
                Text(item.text)
                    .font(DS.FontStyle.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: DS.Space.sm)
                Text(sourceLabel(item))
                    .font(DS.FontStyle.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Color.dfAccent.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The day the task was last left open, plus how many other days carry the
    /// same text (all of which get cleaned up together).
    private func sourceLabel(_ item: CarryoverItem) -> String {
        let day = DF.shortMonthDay.string(from: item.latestDate)
        guard item.sources.count > 1 else { return day }
        return "\(day) +\(item.sources.count - 1)"
    }
}
