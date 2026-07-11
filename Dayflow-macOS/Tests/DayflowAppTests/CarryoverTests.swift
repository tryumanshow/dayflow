import Testing
import Foundation
@testable import DayflowApp

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-carry-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

/// Carry-over is only ever offered on today, and `pendingCarryovers` looks a
/// fixed number of days back from its target — so the fixture has to be
/// anchored to the real current date, not a hardcoded one.
private func daysAgo(_ n: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: -n,
                          to: Calendar.current.startOfDay(for: Date()))!
}

private func today() -> Date {
    Calendar.current.startOfDay(for: Date())
}

@MainActor
private func makeStore() -> DayflowStore {
    let store = DayflowStore(db: tempDB())
    store.selectedDate = today()
    return store
}

// MARK: - discovery

@MainActor
@Test func findsOnlyUncheckedTasksFromPastDays() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: """
        # yesterday
        - [ ] ship the thing
        - [x] already done
        just a plain line
        """)

    let pending = store.pendingCarryovers(into: today())
    #expect(pending.map(\.text) == ["ship the thing"])
}

@MainActor
@Test func ignoresTasksOlderThanTheLookbackWindow() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(3), body: "- [ ] recent")
    store.db.saveDayNote(date: daysAgo(30), body: "- [ ] ancient")

    let pending = store.pendingCarryovers(into: today())
    #expect(pending.map(\.text) == ["recent"])
}

/// Today's own page is never a source — otherwise an unfinished task written
/// this morning would immediately offer to carry itself over.
@MainActor
@Test func ignoresTodayItself() {
    let store = makeStore()
    store.db.saveDayNote(date: today(), body: "- [ ] written today")

    #expect(store.pendingCarryovers(into: today()).isEmpty)
}

/// If the task is already on today's page — carried by an earlier run, or
/// retyped by hand — don't offer it again.
@MainActor
@Test func skipsTasksAlreadyPresentOnTarget() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] Ship The Thing\n- [ ] other")
    store.db.saveDayNote(date: today(), body: "- [ ] ship the thing")

    let pending = store.pendingCarryovers(into: today())
    #expect(pending.map(\.text) == ["other"])
}

/// The same text open on several past days is one item with several sources —
/// carrying it writes ONE line today and clears the checkbox off every day.
@MainActor
@Test func collapsesDuplicateTextAcrossDaysIntoOneItem() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(3), body: "- [ ] recurring chore")
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] recurring chore")

    let pending = store.pendingCarryovers(into: today())
    #expect(pending.count == 1)
    #expect(pending.first?.sources.count == 2)
    // Reported against the most recent day it was left open on.
    #expect(DayflowDB.ymd(pending[0].latestDate) == DayflowDB.ymd(daysAgo(1)))
}

// MARK: - the move

@MainActor
@Test func carryOverMovesTaskToTodayAndClearsTheSource() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: """
        # yesterday
        - [ ] ship the thing
        - [x] already done
        """)

    let pending = store.pendingCarryovers(into: today())
    store.carryOver(pending, into: today())

    let source = store.db.getDayNote(date: daysAgo(1))
    #expect(!source.contains("ship the thing"))
    // Only the carried line leaves — everything else on the day survives.
    #expect(source.contains("# yesterday"))
    #expect(source.contains("- [x] already done"))

    #expect(store.db.getDayNote(date: today()).contains("- [ ] ship the thing"))
}

@MainActor
@Test func carryOverAppendsBelowExistingContent() {
    let store = makeStore()
    store.db.saveDayNote(date: today(), body: "# today\n- [x] morning run")
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] carried")

    store.carryOver(store.pendingCarryovers(into: today()), into: today())

    let body = store.db.getDayNote(date: today())
    #expect(body == "# today\n- [x] morning run\n- [ ] carried\n")
}

@MainActor
@Test func carryOverClearsEverySourceOfACollapsedItem() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(3), body: "- [ ] recurring chore")
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] recurring chore")

    store.carryOver(store.pendingCarryovers(into: today()), into: today())

    #expect(store.db.getDayNote(date: daysAgo(3)).isEmpty)
    #expect(store.db.getDayNote(date: daysAgo(1)).isEmpty)
    // One line today, not two.
    let todayBody = store.db.getDayNote(date: today())
    #expect(todayBody == "- [ ] recurring chore\n")
}

@MainActor
@Test func carryOverOnlyMovesTheSelectedSubset() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] take me\n- [ ] leave me")

    let pending = store.pendingCarryovers(into: today())
    let picked = pending.filter { $0.text == "take me" }
    store.carryOver(picked, into: today())

    let source = store.db.getDayNote(date: daysAgo(1))
    #expect(!source.contains("take me"))
    #expect(source.contains("- [ ] leave me"))
    #expect(store.db.getDayNote(date: today()).contains("- [ ] take me"))
}

/// The list the sheet acts on is captured when it opens. If the source day
/// changed underneath (an edit landed, the task got ticked off), deleting
/// blindly by line index would take out the wrong line. A stale source is
/// skipped instead.
@MainActor
@Test func staleLineIndexIsSkippedRatherThanDeletingTheWrongLine() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] target\n- [ ] bystander")

    let pending = store.pendingCarryovers(into: today())
    let target = pending.first { $0.text == "target" }!
    #expect(target.sources.first?.lineIndex == 0)

    // The day is rewritten behind our back: the task at index 0 is now a
    // different, unrelated line.
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] something else entirely\n- [ ] bystander")

    store.carryOver([target], into: today())

    // Nothing was deleted — index 0 no longer holds "target".
    let source = store.db.getDayNote(date: daysAgo(1))
    #expect(source.contains("- [ ] something else entirely"))
    #expect(source.contains("- [ ] bystander"))
}

@MainActor
@Test func carryOverOfNothingIsANoOp() {
    let store = makeStore()
    store.db.saveDayNote(date: today(), body: "# untouched")
    store.carryOver([], into: today())
    #expect(store.db.getDayNote(date: today()) == "# untouched")
}

/// The in-memory buffers the editor renders from have to follow the DB, or the
/// carried task wouldn't appear until the next reload.
@MainActor
@Test func carryOverUpdatesTheInMemoryDayBuffer() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] carried")
    store.refresh(force: true)

    store.carryOver(store.pendingCarryovers(into: today()), into: today())

    #expect(store.dayBody.contains("- [ ] carried"))
    #expect(store.bodies[DayflowDB.ymd(daysAgo(1))]?.contains("carried") == false)
}
