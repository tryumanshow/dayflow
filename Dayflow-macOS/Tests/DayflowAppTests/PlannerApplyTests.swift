import Testing
import Foundation
@testable import DayflowApp

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-planapply-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func day(_ offset: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: offset,
                          to: Calendar.current.startOfDay(for: Date()))!
}

@MainActor
private func makeStore() -> DayflowStore {
    let store = DayflowStore(db: tempDB())
    store.selectedDate = Calendar.current.startOfDay(for: Date())
    return store
}

private func draft(_ entries: [(Date, [String])]) -> PlanDraft {
    PlanDraft(
        days: entries.map { date, titles in
            PlanDay(date: DayflowDB.ymd(date), tasks: titles.map { PlanTask(title: $0, note: nil) })
        },
        unassigned: [], rationale: ""
    )
}

@MainActor
@Test func applyPlanWritesSectionIntoEachDay() {
    let store = makeStore()
    store.db.saveDayNote(date: day(0), body: "- [ ] hand written")

    let replaced = store.applyPlan(draft([(day(0), ["a"]), (day(1), ["b", "c"])]))

    let d0 = store.db.getDayNote(date: day(0))
    #expect(d0.contains("- [ ] hand written"))
    #expect(d0.contains("## 📋 Plan"))
    #expect(d0.contains("- [ ] a"))
    let d1 = store.db.getDayNote(date: day(1))
    #expect(d1.contains("- [ ] b"))
    #expect(d1.contains("- [ ] c"))
    #expect(replaced.isEmpty)  // nothing pre-existing
}

@MainActor
@Test func applyPlanReplacesAndReportsExistingSections() {
    let store = makeStore()
    store.db.saveDayNote(date: day(0), body: "## 📋 Plan (old)\n- [x] finished\n- [ ] stale")

    let replaced = store.applyPlan(draft([(day(0), ["fresh"])]))

    let body = store.db.getDayNote(date: day(0))
    #expect(body.contains("- [x] finished"))
    #expect(!body.contains("stale"))
    #expect(body.contains("- [ ] fresh"))
    #expect(replaced == [DayflowDB.ymd(day(0))])
}

@MainActor
@Test func applyPlanSkipsInvalidDateStrings() {
    let store = makeStore()
    let bad = PlanDraft(
        days: [PlanDay(date: "not-a-date", tasks: [PlanTask(title: "x", note: nil)])],
        unassigned: [], rationale: ""
    )
    let replaced = store.applyPlan(bad)
    #expect(replaced.isEmpty)
}

@MainActor
@Test func applyPlanUpdatesInMemoryDayBuffer() {
    let store = makeStore()
    _ = store.applyPlan(draft([(store.selectedDate, ["visible now"])]))
    #expect(store.dayBody.contains("- [ ] visible now"))
}

@MainActor
@Test func datesWithExistingPlanDetectsOnlyPlanSections() {
    let store = makeStore()
    store.db.saveDayNote(date: day(0), body: "## 📋 Plan (old)\n- [ ] x")
    store.db.saveDayNote(date: day(1), body: "## some other heading\n- [ ] y")

    let d = draft([(day(0), ["a"]), (day(1), ["b"])])
    #expect(store.datesWithExistingPlan(in: d) == [DayflowDB.ymd(day(0))])
}
