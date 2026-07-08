import Testing
import Foundation
@testable import DayflowApp

@Test func parseCheckboxesCountsOpenAndDone() {
    let body = """
    - [ ] open one
    - [x] done one
    - [ ] open two
    plain text line
    """
    let counts = DayflowDB.parseCheckboxes(body)
    #expect(counts.open == 2)
    #expect(counts.done == 1)
}

@Test func parseCheckboxesEmptyBody() {
    let counts = DayflowDB.parseCheckboxes("")
    #expect(counts.open == 0)
    #expect(counts.done == 0)
}

@Test func ymdAndMonthKeyFormat() {
    let d = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 9))!
    #expect(DayflowDB.ymd(d) == "2026-03-09")
    #expect(DayflowDB.monthKey(d) == "2026-03")
}
