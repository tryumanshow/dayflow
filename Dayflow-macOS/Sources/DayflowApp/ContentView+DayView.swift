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
            .padding(.top, DS.Space.lg)
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
                            weekStripRail
                            daySummaryRail
                            appointmentsRail
                            onHoldRail
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

    /// The selected week as seven rings (fill = that day's done ratio), so
    /// the Day view keeps its place in the week without switching modes.
    private var weekStripRail: some View {
        let cal = Calendar.current
        let start = store.startOfWeek(store.selectedDate)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        return HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                let counts = store.dayCounts(day)
                let total = counts.open + counts.done
                let ratio = total == 0 ? 0 : Double(counts.done) / Double(total)
                let isToday = cal.isDateInToday(day)
                let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
                Button {
                    store.selectDate(day)
                } label: {
                    VStack(spacing: 4) {
                        Text(DF.weekday.string(from: day))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isToday ? Color.dfAccent : .secondary)
                        ZStack {
                            Circle().stroke(Color.primary.opacity(total == 0 ? 0.06 : 0.12), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: ratio)
                                .stroke(Color.dfDone, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(DF.dayNumber.string(from: day))
                                .font(.system(size: 10, weight: isToday ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(isToday ? Color.dfAccent : .primary)
                        }
                        .frame(width: 26, height: 26)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? Color.dfAccent.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(total == 0 ? DF.shortMonthDay.string(from: day)
                                 : "\(DF.shortMonthDay.string(from: day)) · \(counts.done)/\(total)")
            }
        }
    }

    /// Today's progress, broken down by the note's own headings. A single big
    /// percentage said little ("0%" every morning); per-section bars show
    /// where the day actually stands, and each row jumps the editor there.
    private var daySummaryRail: some View {
        let counts = DayflowDB.parseCheckboxes(store.dayBody)
        let total = counts.open + counts.done
        let sections = DayflowStore.sectionProgress(of: store.dayBody)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("day.today_progress"))
                Spacer()
                if total + counts.onHold > 0 {
                    HStack(spacing: 6) {
                        Text(L("day.done_of_total", counts.done, total))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if counts.onHold > 0 {
                            Text(L("day.held_format", counts.onHold))
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(Color.dfHold)
                        }
                    }
                }
            }
            if total + counts.onHold == 0 {
                Text(L("day.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            } else {
                progressBar(done: counts.done, total: total, height: 4)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        sectionRow(section)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func sectionRow(_ section: SectionProgress) -> some View {
        Button {
            if let title = section.title {
                NotificationCenter.default.post(name: .dayflowScrollToHeading, object: title)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(section.title ?? L("day.section_untitled"))
                        .font(DS.FontStyle.body)
                        .foregroundStyle(section.title == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if section.onHold > 0 {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.dfHold)
                    }
                    Text("\(section.done)/\(section.total)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(section.total > 0 && section.done == section.total ? Color.dfDone : .secondary)
                }
                progressBar(done: section.done, total: section.total, height: 3)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailRowButtonStyle())
        .help(section.title.map { L("day.section_jump", $0) } ?? "")
    }

    private func progressBar(done: Int, total: Int, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.dfDone.opacity(0.9))
                    .frame(width: total == 0 ? 0 : geo.size.width * CGFloat(done) / CGFloat(total))
            }
        }
        .frame(height: height)
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
                if items.isEmpty {
                    // One line instead of a header plus an empty-state row.
                    Text(L("appointments.none_short"))
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                }
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
            if !items.isEmpty {
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

    /// Parked tasks from the last few weeks. Hidden when there are none, so
    /// it costs nothing on a day without any.
    @ViewBuilder
    private var onHoldRail: some View {
        let items = store.onHoldTasks(upTo: store.selectedDate)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                SectionLabel(text: L("onhold.header", items.count))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        Button {
                            store.selectDate(item.date)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "pause.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.dfHold)
                                Text(item.text)
                                    .font(DS.FontStyle.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(DF.shortMonthDay.string(from: item.date))
                                    .font(DS.FontStyle.micro)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("onhold.open_day"))
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
            // Nothing below the header until there's a review: the Generate
            // button says what this is, a placeholder paragraph only padded it.
            if !store.reviewBody.isEmpty {
                ReviewMarkdownView(text: store.reviewBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Rail rows that act on click: a faint fill on hover and press, so the row
/// reads as clickable without drawing button chrome in a read-only column.
private struct RailRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0)))
            )
            .onHover { hovering = $0 }
    }
}
