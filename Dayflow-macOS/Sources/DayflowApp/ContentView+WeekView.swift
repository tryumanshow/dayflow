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

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                    if idx > 0 {
                        Rectangle().fill(Color.dfHairlineSoft).frame(width: 0.7)
                    }
                    weekColumn(for: day)
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

    private func weekColumn(for day: Date) -> some View {
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
                            Capsule().fill(Color.white.opacity(0.06))
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

            let dayAppointments = store.appointments(for: day)
            if !dayAppointments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dayAppointments) { apt in
                        HStack(spacing: 4) {
                            Text(DF.hourMinute.string(from: apt.startAt))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.dfAccent)
                            if let pill = Self.durationPill(from: apt.startAt, to: apt.endAt) {
                                Text(pill)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(apt.title)
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        weekGroupView(group, day: day)
                    }
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
                    .lineLimit(1)
            }
            ForEach(group.tasks) { task in
                if task.isTask {
                    Button {
                        store.toggleWeekTask(day: day, sourceLineIndex: task.sourceLineIndex)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 10))
                                .foregroundStyle(task.checked ? Color.dfAccent : .secondary)
                            Text(task.text)
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(task.checked ? .tertiary : .secondary)
                                .strikethrough(task.checked)
                                .lineLimit(1)
                        }
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
                            .lineLimit(1)
                    }
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
