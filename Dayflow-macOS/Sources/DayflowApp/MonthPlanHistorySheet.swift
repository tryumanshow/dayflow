import SwiftUI

/// Identifiable wrapper so `.sheet(item:)` can key on a plain Int64.
struct IdentifiedSectionId: Identifiable, Hashable {
    let id: Int64
}

/// Recovery sheet for the per-section history snapshots written by
/// `DayflowDB.updateMonthPlanSection`. Lists every snapshot most-recent
/// first with a markdown preview; clicking "복원" overwrites the live
/// section body with the chosen snapshot. The current body itself is
/// snapshotted by the same write path before the restore lands, so a
/// restore is itself reversible.
struct MonthPlanHistorySheet: View {
    let sectionId: Int64
    let store: DayflowStore
    let onClose: () -> Void

    @State private var entries: [DayflowDB.MonthPlanSectionHistoryEntry] = []
    @State private var selectedEntryId: Int64? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("month.plan.history.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("common.close")) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Text(L("month.plan.history.empty"))
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.secondary)
                    Text(L("month.plan.history.hint"))
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                HSplitView {
                    List(entries, id: \.id, selection: $selectedEntryId) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.savedAt)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                            Text("\(entry.bodyMd.count) \(L("month.plan.history.chars"))  ·  \(entry.reason)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                    }
                    .frame(minWidth: 220)

                    VStack(alignment: .leading, spacing: 8) {
                        if let entry = currentEntry {
                            ScrollView {
                                Text(entry.bodyMd.isEmpty ? "(empty)" : entry.bodyMd)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(12)
                            }
                            .background(Color.black.opacity(0.15))
                            .cornerRadius(6)
                            HStack {
                                Spacer()
                                Button(L("month.plan.history.restore")) {
                                    restore(entry)
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(entry.bodyMd.isEmpty)
                            }
                        } else {
                            Text(L("month.plan.history.select_hint"))
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(12)
                    .frame(minWidth: 320)
                }
            }
        }
        .frame(width: 720, height: 480)
        .onAppear { reload() }
    }

    private var currentEntry: DayflowDB.MonthPlanSectionHistoryEntry? {
        guard let id = selectedEntryId else { return entries.first }
        return entries.first(where: { $0.id == id })
    }

    @MainActor
    private func reload() {
        entries = store.monthPlanSectionHistory(id: sectionId)
        if selectedEntryId == nil { selectedEntryId = entries.first?.id }
    }

    @MainActor
    private func restore(_ entry: DayflowDB.MonthPlanSectionHistoryEntry) {
        store.updateMonthPlanSection(id: sectionId, body: entry.bodyMd, bodyJSON: entry.bodyJSON)
        onClose()
    }
}
