import SwiftUI
import AppKit

@MainActor
extension ContentView {
    // MARK: - day view (asymmetric: editor left, small rail right) ----------

    var dayView: some View {
        VStack(spacing: 0) {
            carryoverBanner
            dayColumns
        }
        .task(id: DayflowDB.ymd(store.selectedDate)) {
            let key = DayflowDB.ymd(store.selectedDate)
            if store.carryoverBannerDismissed(for: store.selectedDate) {
                carryoverDismissed.insert(key)
            }
            carryoverPending = store.pendingCarryovers(into: store.selectedDate)
        }
        .sheet(item: $carryoverBatch) { batch in
            CarryoverSheet(
                items: batch.items,
                onCarry: { picked in
                    store.carryOver(picked, into: store.selectedDate)
                    carryoverBatch = nil
                    carryoverPending = store.pendingCarryovers(into: store.selectedDate)
                    // Whatever the user left unticked, they left on purpose —
                    // re-prompting on the same day would just nag.
                    dismissCarryover()
                },
                onCancel: { carryoverBatch = nil }
            )
        }
    }

    /// Only surfaces on today: carrying a task into a day that has already
    /// passed (or hasn't arrived yet) isn't something the user means to do.
    @ViewBuilder
    private var carryoverBanner: some View {
        let key = DayflowDB.ymd(store.selectedDate)
        if Calendar.current.isDateInToday(store.selectedDate),
           !carryoverDismissed.contains(key),
           !carryoverPending.isEmpty {
            CarryoverBanner(
                count: carryoverPending.count,
                onReview: {
                    // Re-read at open time rather than trusting the cache —
                    // the notes may have moved since the day was loaded, and
                    // this list is about to authorize deletions.
                    let fresh = store.pendingCarryovers(into: store.selectedDate)
                    carryoverPending = fresh
                    guard !fresh.isEmpty else { return }
                    carryoverBatch = CarryoverBatch(items: fresh)
                },
                onDismiss: { dismissCarryover() }
            )
        }
    }

    private func dismissCarryover() {
        store.dismissCarryoverBanner(for: store.selectedDate)
        carryoverDismissed.insert(DayflowDB.ymd(store.selectedDate))
    }

    private var dayColumns: some View {
        @Bindable var store = store
        return GeometryReader { geo in
          // Same narrow-display guard as the month view: drop the rail
          // (and its drag handle) when there isn't room for it at its own
          // minimum width, so the editor takes the full width instead of
          // the two columns overflowing the window on a scaled display.
          let editorMin: CGFloat = 360
          let handleW: CGFloat = 10
          let railMin: CGFloat = 300
          let railCap = max(0, geo.size.width - editorMin - handleW)
          let railVisible = !sideRailHidden && railCap >= railMin
          let railW = min(displayRailWidth, railCap)
          HStack(alignment: .top, spacing: 0) {
            MarkdownWebEditor(
                markdown: $store.dayBody,
                markdownJSON: $store.dayBodyJSON,
                fontSize: dayEditorFontSize,
                onChange: { newMD, newJSON in
                    store.updateDayBody(newMD, bodyJSON: newJSON)
                }
            )
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.breathe)
            .padding(.bottom, DS.Space.lg)
            .layoutPriority(1)

            if railVisible {
                // Draggable divider between editor and side rail (AppKit-backed).
                HorizontalResizeHandle(
                    onDrag: { dx in
                        let base = liveRailWidth ?? sideRailWidth
                        liveRailWidth = max(300, min(500, base - Double(dx)))
                    },
                    onEnd: {
                        if let v = liveRailWidth { sideRailWidth = v; liveRailWidth = nil }
                    }
                )
                .frame(minWidth: 10, maxWidth: 10, maxHeight: .infinity)

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.breathe) {
                            daySummaryRail
                            appointmentsRail
                            reviewRail
                        }
                        .padding(.horizontal, DS.Space.xl)
                        .padding(.top, DS.Space.breathe)
                        .padding(.bottom, DS.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    appCredit
                }
                .frame(width: railW)
                .frame(maxHeight: .infinity)
                .background(Color.dfQuiet)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
          }
        }
    }

    /// Tiny attribution line shown at the bottom of the side rails. Kept in
    /// `micro` mono font with tertiary opacity so it sits quietly and never
    /// competes with rail content.
    var appCredit: some View {
        HStack(spacing: 0) {
            Text("Dayflow · by ")
                .foregroundStyle(.tertiary)
            Text("tryumanshow")
                .foregroundStyle(.secondary)
        }
        .font(DS.FontStyle.micro)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dfHairline).frame(height: 0.7)
        }
    }

    private var daySummaryRail: some View {
        let counts = DayflowDB.parseCheckboxes(store.dayBody)
        let total = counts.open + counts.done
        let ratio = total == 0 ? 0.0 : Double(counts.done) / Double(total)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            SectionLabel(text: L("day.today_progress"))
            HStack(alignment: .bottom, spacing: 4) {
                Text("\(Int(ratio * 100))")
                    .font(DS.FontStyle.metric)
                    .foregroundStyle(Color.dfAccent)
                Text("%")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            if total > 0 {
                Text(L("day.done_open_format", counts.done, counts.open))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("day.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Day rail is read-only for appointments — creation and deletion
    /// both live in the Month view so there's a single place to shape
    /// the month's schedule.
    @ViewBuilder
    private var appointmentsRail: some View {
        let items = store.appointments(for: store.selectedDate)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("appointments.header"))
                Spacer()
                Button {
                    store.setMode(.month)
                } label: {
                    Text(L("appointments.manage_in_month"))
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(Color.dfAccent)
                }
                .buttonStyle(.plain)
            }
            if items.isEmpty {
                Text(L("appointments.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { apt in
                        HStack(spacing: 8) {
                            Text(apt.timeLabel)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.dfAccent)
                                .fixedSize()
                            if apt.source == .google {
                                Image(systemName: "g.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .help(L("gcal.mirrored_hint"))
                            }
                            if let pill = Self.durationPill(from: apt.startAt, to: apt.endAt) {
                                Text(pill)
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                            Text(apt.title)
                                .font(DS.FontStyle.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(apt.category.color.opacity(0.22))
                                )
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var reviewRail: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                SectionLabel(text: L("day.ai_review"))
                Spacer()
                if store.reviewIsLoading {
                    ProgressView().controlSize(.small)
                } else if store.reviewBody.isEmpty {
                    Button {
                        store.generateReview()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .bold))
                            Text(L("day.generate"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.dfAccent.opacity(0.14))
                        )
                        .foregroundStyle(Color.dfAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let err = store.reviewError {
                Text(err)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.red)
            }
            if store.reviewBody.isEmpty {
                Text(L("day.review_placeholder"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, DS.Space.sm)
            } else {
                ReviewMarkdownView(text: store.reviewBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
