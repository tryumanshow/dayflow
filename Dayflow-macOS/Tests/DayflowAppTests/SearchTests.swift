import Testing
import Foundation
@testable import DayflowApp

private func searchDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-search-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
}

// MARK: - day notes

@Test func searchDayNotesFindsSubstring() {
    let db = searchDB()
    db.saveDayNote(date: day(2026, 6, 15), body: "회의록: 팀과 meeting 진행. deploy 파이프라인 논의.")
    db.saveDayNote(date: day(2026, 7, 1), body: "RabbitMQ 설정 확인")

    #expect(db.searchDayNotes("deploy").count == 1)
    #expect(db.searchDayNotes("RabbitMQ").count == 1)
    #expect(db.searchDayNotes("nothing here").isEmpty)
}

/// The reason we use LIKE rather than FTS5: the default `unicode61`
/// tokenizer treats a whole CJK run as one token, so an FTS match on a
/// Korean *substring* would silently return nothing.
@Test func searchDayNotesMatchesKoreanSubstring() {
    let db = searchDB()
    db.saveDayNote(date: day(2026, 7, 8), body: "치과 다녀옴. 다음 예약 잡아야 함.")

    #expect(db.searchDayNotes("치과").count == 1)
    // Mid-word slice — the case FTS5 would miss.
    #expect(db.searchDayNotes("다녀").count == 1)
    #expect(db.searchDayNotes("예약").count == 1)
}

@Test func searchDayNotesIsCaseInsensitive() {
    let db = searchDB()
    db.saveDayNote(date: day(2026, 7, 1), body: "Deploy Pipeline")

    #expect(db.searchDayNotes("deploy").count == 1)
    #expect(db.searchDayNotes("PIPELINE").count == 1)
}

@Test func searchDayNotesOrdersNewestFirst() {
    let db = searchDB()
    db.saveDayNote(date: day(2026, 5, 1), body: "deploy old")
    db.saveDayNote(date: day(2026, 7, 1), body: "deploy new")
    db.saveDayNote(date: day(2026, 6, 1), body: "deploy mid")

    let dates = db.searchDayNotes("deploy").map { DayflowDB.ymd($0.date) }
    #expect(dates == ["2026-07-01", "2026-06-01", "2026-05-01"])
}

@Test func searchDayNotesHonoursLimit() {
    let db = searchDB()
    for i in 1...5 { db.saveDayNote(date: day(2026, 7, i), body: "deploy \(i)") }
    #expect(db.searchDayNotes("deploy", limit: 2).count == 2)
}

/// `%` and `_` are LIKE wildcards. Un-escaped, a query of "_" would match
/// every note that has at least one character.
@Test func searchDayNotesTreatsWildcardsAsLiterals() {
    let db = searchDB()
    db.saveDayNote(date: day(2026, 7, 1), body: "coverage is 90% today")
    db.saveDayNote(date: day(2026, 7, 2), body: "no percent sign here")
    db.saveDayNote(date: day(2026, 7, 3), body: "snake_case name")

    #expect(db.searchDayNotes("90%").count == 1)
    // A bare "%" must match only the note that literally contains one,
    // not all three.
    #expect(db.searchDayNotes("%").count == 1)
    #expect(db.searchDayNotes("_").count == 1)
    #expect(db.searchDayNotes("snake_case").count == 1)
}

// MARK: - appointments

@Test func searchAppointmentsMatchesTitle() {
    let db = searchDB()
    _ = db.insertAppointment(startAt: day(2026, 7, 20), endAt: nil,
                             title: "치과 예약", note: nil, category: .reminder)
    _ = db.insertAppointment(startAt: day(2026, 6, 30), endAt: nil,
                             title: "meeting with design team", note: nil, category: .event)

    #expect(db.searchAppointments("치과").count == 1)
    #expect(db.searchAppointments("meeting").first?.category == .event)
    #expect(db.searchAppointments("nope").isEmpty)
}

// MARK: - month plan sections

@Test func searchMonthPlanMatchesTitleOrBody() {
    let db = searchDB()
    let id = db.addMonthPlanSection(date: day(2026, 7, 1), title: "Career", sortOrder: 0)
    db.updateMonthPlanSection(id: id, body: "learn Rust and ship the deploy tooling", bodyJSON: nil)

    #expect(db.searchMonthPlanSections("Career").count == 1)   // title hit
    #expect(db.searchMonthPlanSections("Rust").count == 1)     // body hit
    #expect(db.searchMonthPlanSections("Career").first?.monthKey == "2026-07")
    #expect(db.searchMonthPlanSections("absent").isEmpty)
}

// MARK: - snippet

@Test func snippetWindowsAroundTheMatch() {
    let body = String(repeating: "a", count: 200) + "NEEDLE" + String(repeating: "b", count: 200)
    let out = DayflowStore.snippet(from: body, matching: "NEEDLE", window: 10)
    #expect(out == "…aaaaaaaaaaNEEDLEbbbbbbbbbb…")
}

@Test func snippetFlattensNewlines() {
    let out = DayflowStore.snippet(from: "line one\nline two", matching: "two")
    #expect(!out.contains("\n"))
    #expect(out.contains("line one line two"))
}

/// A title-only appointment hit has no body containing the query; the
/// snippet must still produce something rather than crash or blank out.
@Test func snippetFallsBackToHeadWhenQueryAbsent() {
    let out = DayflowStore.snippet(from: "some body text", matching: "notpresent")
    #expect(out == "some body text")
}

// MARK: - store composition (reproduces what the overlay actually shows)

@MainActor
@Test func storeSearchComposesTheRightKinds() {
    let store = DayflowStore(db: searchDB())
    store.db.saveDayNote(date: day(2026, 7, 11), body: "- [ ] deploy 파이프라인 고치기\n- [ ] 치과 예약 잡기")
    _ = store.db.insertAppointment(startAt: day(2026, 7, 11), endAt: nil,
                                   title: "meeting with design team", note: nil, category: .event)
    _ = store.db.insertAppointment(startAt: day(2026, 7, 12), endAt: nil,
                                   title: "치과 예약", note: nil, category: .reminder)
    let sec = store.db.addMonthPlanSection(date: day(2026, 7, 1), title: "Career", sortOrder: 0)
    store.db.updateMonthPlanSection(id: sec, body: "learn Rust and ship the deploy tooling", bodyJSON: nil)

    let hits = store.search("deploy")
    let kinds = hits.map(\.kind)
    let titles = hits.map(\.title)

    // An appointment titled "meeting with design team" does NOT contain
    // "deploy" and must not appear; the month plan body does and must.
    #expect(!kinds.contains(.appointment), "got: \(titles)")
    #expect(kinds.contains(.monthPlan), "got: \(titles)")
    #expect(kinds.contains(.dayNote), "got: \(titles)")
    #expect(hits.count == 2, "got: \(titles)")
}
