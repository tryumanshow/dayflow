import SwiftUI
import AppKit

@MainActor
extension ContentView {
    // MARK: - week view ------------------------------------------------------

    var weekView: some View {
        let cal = Calendar.current
        let weekStart = store.startOfWeek(store.selectedDate)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let totals = store.weekTotals()
        let spans = Self.spanLayout(for: store.currentMonthSpans(), gridDays: days, cal: cal)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                    if idx > 0 {
                        Rectangle().fill(Color.dfHairlineSoft).frame(width: 0.7)
                    }
                    weekColumn(for: day, index: idx, spans: spans)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.breathe)

            Rectangle().fill(Color.dfHairline).frame(height: 0.7)

            HStack(spacing: DS.Space.lg) {
                Spacer()
                weekFooterStat(value: "\(totals.done)", label: L("week.footer.done"))
                weekFooterStat(value: "\(totals.open)", label: L("week.footer.open"))
                weekFooterStat(value: "\(totals.trackedDays)",
                               label: L(totals.trackedDays == 1 ? "week.footer.day_tracked" : "week.footer.days_tracked"))
                Spacer()
            }
            .padding(.vertical, DS.Space.md)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    Text("Dayflow · by ")
                        .foregroundStyle(.tertiary)
                    Text("tryumanshow")
                        .foregroundStyle(.secondary)
                }
                .font(DS.FontStyle.micro)
                .padding(.trailing, DS.Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func weekColumn(for day: Date, index: Int, spans: SpanLayout) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let counts = store.dayCounts(day)
        let total = counts.open + counts.done
        let ratio = total == 0 ? 0.0 : Double(counts.done) / Double(total)
        let groups = store.weekGroups(for: day)

        return VStack(alignment: .leading, spacing: DS.Space.md) {
            // Top accent bar when selected. Tap area belongs to the header.
            Rectangle()
                .fill(isSelected ? Color.dfAccent : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, DS.Space.xs)

            VStack(alignment: .leading, spacing: 6) {
                Text(DF.weekday.string(from: day).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(isToday ? Color.dfAccent : .secondary)
                Text(DF.dayNumber.string(from: day))
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundColor(isToday ? Color.dfAccent : .primary)
                if let holidayName = HolidayStore.holidayName(on: day, mode: holidaysMode) {
                    Text(holidayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dfHoliday)
                        .lineLimit(1)
                }
                if total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(Color.dfAccent).frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 3)
                } else {
                    // Keep vertical rhythm identical on empty days — no placeholder glyph.
                    Color.clear.frame(height: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectDate(day)
                store.setMode(.day)
            }

            // Multi-day appointments: every column draws its piece of each
            // bar in a fixed lane, stretched to the column edges, so the
            // pieces join into one bar across the week.
            let laneCount = spans.laneCount(weekStartIdx: 0)
            if laneCount > 0 {
                VStack(alignment: .leading, spacing: Self.spanLaneGap) {
                    ForEach(0..<laneCount, id: \.self) { lane in
                        if let entry = spans.entries.first(where: { $0.lane == lane && $0.startIdx <= index && $0.endIdx >= index }) {
                            weekSpanSegment(entry.apt, day: day, isWeekStart: index == 0)
                        } else {
                            Color.clear.frame(height: Self.weekSpanHeight)
                        }
                    }
                }
                .padding(.horizontal, -DS.Space.md)
            }

            let dayAppointments = store.appointments(for: day)
            if !dayAppointments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dayAppointments) { apt in
                        // No duration pill here. A week column is ~140pt wide,
                        // and time + "1h 30m" + title all competing for it is
                        // what truncated every title to "Dentist foll…". The
                        // duration is the least useful of the three at a
                        // glance, so it stays in the Day rail only and the
                        // title gets the room back.
                        HStack(alignment: .top, spacing: 4) {
                            Text(apt.timeLabel)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.dfAccent)
                                .fixedSize()
                            Text(apt.title)
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(apt.category.color.opacity(0.22))
                                )
                        }
                    }
                }
            }

            if !groups.isEmpty {
                // Wrapped titles can outgrow the window on a busy day; the
                // list scrolls inside its column instead of stretching the
                // whole view and pushing the nav bar and footer off screen.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups) { group in
                            weekGroupView(group, day: day)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? Color.dfAccent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.selectDate(day)
            store.setMode(.day)
        }
        .onTapGesture(count: 1) {
            store.selectDate(day)
        }
        .animation(DS.Motion.quick, value: isSelected)
    }

    static let weekSpanHeight: CGFloat = 16

    private func weekSpanSegment(_ apt: Appointment, day: Date, isWeekStart: Bool) -> some View {
        let cal = Calendar.current
        let isStart = cal.isDate(day, inSameDayAs: apt.startAt)
        let isEnd = apt.endAt.map { cal.isDate(day, inSameDayAs: $0) } ?? true
        let inset = DS.Space.md + Self.spanEndInset
        return Text(isStart || isWeekStart ? apt.title : "")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: Self.weekSpanHeight, maxHeight: Self.weekSpanHeight, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: isStart ? 4 : 0,
                    bottomLeadingRadius: isStart ? 4 : 0,
                    bottomTrailingRadius: isEnd ? 4 : 0,
                    topTrailingRadius: isEnd ? 4 : 0,
                    style: .continuous
                )
                .fill(apt.category.color.opacity(0.55))
            )
            .padding(.leading, isStart ? inset : 0)
            .padding(.trailing, isEnd ? inset : 0)
            .help(apt.endAt.map { "\(apt.title) · \(DF.shortMonthDay.string(from: apt.startAt)) → \(DF.shortMonthDay.string(from: $0))" } ?? apt.title)
    }

    /// One group in a week column: optional heading + its tasks
    /// (both open and done, in source order). Each task has a tappable
    /// checkbox that flips in place without leaving the Week view.
    /// Sub-tasks get a padding-left offset per indent level so the Day
    /// view's nesting carries over.
    private func weekGroupView(_ group: DayflowStore.WeekGroup, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading = group.heading {
                Text(heading)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .help(heading)
            }
            ForEach(group.tasks) { task in
                if task.isTask {
                    Button {
                        store.toggleWeekTask(day: day, sourceLineIndex: task.sourceLineIndex)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: task.onHold ? "pause.square.fill" : (task.checked ? "checkmark.square.fill" : "square"))
                                .font(.system(size: 10))
                                .foregroundStyle(task.onHold ? Color.dfHold : (task.checked ? Color.dfAccent : .secondary))
                            Text(task.text)
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(task.onHold ? Color.dfHold : (task.checked ? Color.secondary.opacity(0.6) : Color.secondary))
                                .strikethrough(task.checked)
                                // Two lines before truncating: seven columns
                                // leave little width, and one line cut most
                                // titles down to their first word.
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .help(task.text)
                        .padding(.leading, CGFloat(min(task.depth, 3)) * 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(task.text)
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help(task.text)
                    .padding(.leading, CGFloat(min(task.depth, 3)) * 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectDate(day)
                        store.setMode(.day)
                    }
                }
            }
        }
    }

    private func weekFooterStat(value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
    }
}
