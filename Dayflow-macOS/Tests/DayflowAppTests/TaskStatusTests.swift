import Testing
import Foundation
@testable import DayflowApp

// MARK: - MarkdownLine tri-state parsing

@Test func parsesOpenDoneAndOnHoldMarks() {
    guard case .task(.open, "todo")? = MarkdownLine.parse("- [ ] todo") else {
        Issue.record("expected open"); return
    }
    guard case .task(.done, "done")? = MarkdownLine.parse("- [x] done") else {
        Issue.record("expected done"); return
    }
    guard case .task(.onHold, "parked")? = MarkdownLine.parse("- [~] parked") else {
        Issue.record("expected onHold"); return
    }
}

@Test func onHoldToleratesBlockNoteStarBullet() {
    // BlockNote emits `*   [~] foo`; the parser must accept it.
    guard case .task(.onHold, "foo")? = MarkdownLine.parse("*   [~] foo") else {
        Issue.record("expected onHold from star bullet"); return
    }
}

@Test func taskStatusIsOpenOnlyForOpen() {
    #expect(TaskStatus.open.isOpen)
    #expect(!TaskStatus.done.isOpen)
    #expect(!TaskStatus.onHold.isOpen)
}

// MARK: - parseCheckboxes buckets

@Test func parseCheckboxesCountsThreeBuckets() {
    let body = """
        - [ ] a
        - [ ] b
        - [x] c
        - [~] d
        - [~] e
        plain line
        # heading
        """
    let counts = DayflowDB.parseCheckboxes(body)
    #expect(counts.open == 2)
    #expect(counts.done == 1)
    #expect(counts.onHold == 2)
}
