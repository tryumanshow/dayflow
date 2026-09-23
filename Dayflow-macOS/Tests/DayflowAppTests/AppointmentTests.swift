import Testing
import Foundation
@testable import DayflowApp

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-apt-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func day(_ ymd: String) -> Date { DF.ymd.date(from: ymd)! }

@MainActor
private func makeStore(on date: String) -> DayflowStore {
    let store = DayflowStore(db: tempDB())
    store.selectedDate = day(date)
    store.reloadAppointments()
    return store
}

/// Knowing the day but not the time: a blank time is an all-day appointment,
/// labelled "All day" rather than "00:00".
@MainActor
@Test func blankTimeSavesAnAllDayAppointment() throws {
    let store = makeStore(on: "2026-09-10")
    #expect(store.addAppointment(on: day("2026-09-10"), hhmm: "  ", title: "dentist, time TBD"))

    let apt = try #require(store.appointments(for: day("2026-09-10")).first)
    #expect(apt.isAllDay)
    #expect(apt.endAt == nil)
    #expect(apt.timeLabel == L("apt.all_day"))
}

@MainActor
@Test func timedAppointmentIsNotAllDay() throws {
    let store = makeStore(on: "2026-09-10")
    #expect(store.addAppointment(on: day("2026-09-10"), hhmm: "0930", endHHmm: "10:30", title: "standup"))
    let apt = try #require(store.appointments(for: day("2026-09-10")).first)
    #expect(!apt.isAllDay)
    #expect(DF.hourMinute.string(from: apt.startAt) == "09:30")
}

/// Editing a timed appointment to a blank time turns it all-day, and back.
@MainActor
@Test func editTogglesAllDay() throws {
    let store = makeStore(on: "2026-09-10")
    store.addAppointment(on: day("2026-09-10"), hhmm: "09:00", title: "x")
    let id = try #require(store.appointments(for: day("2026-09-10")).first?.id)

    store.updateAppointment(id, on: day("2026-09-10"), hhmm: "", title: "x", category: .event)
    #expect(store.appointments(for: day("2026-09-10")).first?.isAllDay == true)

    store.updateAppointment(id, on: day("2026-09-10"), hhmm: "14:00", title: "x", category: .event)
    #expect(store.appointments(for: day("2026-09-10")).first?.isAllDay == false)
}

/// A multi-day appointment shows on every day it covers, with how far in
/// that day is — the Day rail's "day 2 of 4".
@MainActor
@Test func spanCoversEachDayWithItsPosition() {
    let store = makeStore(on: "2026-09-10")
    store.addAppointment(on: day("2026-09-07"), hhmm: "", endDay: day("2026-09-10"), title: "trip")

    #expect(store.spans(covering: day("2026-09-06")).isEmpty)
    let second = store.spans(covering: day("2026-09-08"))
    #expect(second.map(\.apt.title) == ["trip"])
    #expect(second.first?.dayIndex == 2)
    #expect(second.first?.dayCount == 4)
    #expect(store.spans(covering: day("2026-09-10")).first?.dayIndex == 4)
    #expect(store.spans(covering: day("2026-09-11")).isEmpty)
    // Spans are bars, not per-day chips.
    #expect(store.appointments(for: day("2026-09-07")).isEmpty)
    #expect(store.currentMonthSpans().first?.isAllDay == true)
}

/// Overlapping spans stack in separate lanes; back-to-back spans (one ends
/// the day before the next starts) may share a lane.
@MainActor
@Test func overlappingSpansGetTheirOwnLanes() {
    let store = makeStore(on: "2026-09-10")
    store.addAppointment(on: day("2026-09-07"), hhmm: "", endDay: day("2026-09-09"), title: "trip")
    store.addAppointment(on: day("2026-09-08"), hhmm: "", endDay: day("2026-09-11"), title: "conference")
    store.addAppointment(on: day("2026-09-10"), hhmm: "", endDay: day("2026-09-12"), title: "after trip")

    let week = (6...12).map { day(String(format: "2026-09-%02d", $0)) }
    let layout = ContentView.spanLayout(for: store.currentMonthSpans(), gridDays: week, cal: .current)
    let lanes = Dictionary(uniqueKeysWithValues: layout.entries.map { ($0.apt.title, $0.lane) })

    #expect(lanes["trip"] == 0)
    #expect(lanes["conference"] == 1)
    #expect(lanes["after trip"] == 0)
    #expect(layout.laneCount(weekStartIdx: 0) == 2)
}

/// Spans that start after (or end before) the grid aren't drawn at all —
/// they used to be clamped onto the last (or first) day.
@MainActor
@Test func spansOutsideTheGridAreSkipped() {
    let store = makeStore(on: "2026-09-10")
    store.addAppointment(on: day("2026-09-01"), hhmm: "", endDay: day("2026-09-03"), title: "before")
    store.addAppointment(on: day("2026-09-13"), hhmm: "", endDay: day("2026-09-15"), title: "after")
    store.addAppointment(on: day("2026-09-12"), hhmm: "", endDay: day("2026-09-14"), title: "crossing")

    let week = (6...12).map { day(String(format: "2026-09-%02d", $0)) }
    let layout = ContentView.spanLayout(for: store.currentMonthSpans(), gridDays: week, cal: .current)
    #expect(layout.entries.map(\.apt.title) == ["crossing"])
    #expect(layout.entries.first?.startIdx == 6)
}
