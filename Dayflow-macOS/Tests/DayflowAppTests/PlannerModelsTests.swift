import Testing
import Foundation
@testable import DayflowApp

// MARK: - decode: union discriminator

@Test func decodesQuestionsResponse() throws {
    let json = """
        {"status":"questions","questions":[
          {"text":"Which first?","options":["Server","Post"]},
          {"text":"How long for X?"}
        ]}
        """
    let r = try PlannerResponse.decode(fromJSON: json)
    guard case let .questions(qs) = r else {
        Issue.record("expected .questions"); return
    }
    #expect(qs.count == 2)
    #expect(qs[0].options == ["Server", "Post"])
    #expect(qs[1].options == nil)
}

@Test func decodesPlanResponse() throws {
    let json = """
        {"status":"plan",
         "days":[{"date":"2026-07-16","tasks":[{"title":"K8s cost survey","note":"managed vs self-hosted"}]}],
         "unassigned":["ORCA"],
         "rationale":"deps first"}
        """
    let r = try PlannerResponse.decode(fromJSON: json)
    guard case let .plan(draft) = r else {
        Issue.record("expected .plan"); return
    }
    #expect(draft.days.count == 1)
    #expect(draft.days[0].date == "2026-07-16")
    #expect(draft.days[0].tasks[0].title == "K8s cost survey")
    #expect(draft.days[0].tasks[0].note == "managed vs self-hosted")
    #expect(draft.unassigned == ["ORCA"])
    #expect(draft.rationale == "deps first")
}

@Test func decodeToleratesCodeFence() throws {
    let json = """
        ```json
        {"status":"plan","days":[],"unassigned":[],"rationale":"r"}
        ```
        """
    let r = try PlannerResponse.decode(fromJSON: json)
    guard case .plan = r else { Issue.record("expected .plan"); return }
}

@Test func decodeMissingStatusThrows() {
    #expect(throws: (any Error).self) {
        _ = try PlannerResponse.decode(fromJSON: #"{"days":[]}"#)
    }
}

@Test func decodeQuestionsStatusWithoutQuestionsThrows() {
    #expect(throws: (any Error).self) {
        _ = try PlannerResponse.decode(fromJSON: #"{"status":"questions"}"#)
    }
}

@Test func decodePlanStatusWithMissingFieldsDefaultsEmpty() throws {
    // A plan missing optional collections should not hard-fail: days is
    // required, unassigned/rationale default to empty.
    let r = try PlannerResponse.decode(fromJSON: #"{"status":"plan","days":[]}"#)
    guard case let .plan(draft) = r else { Issue.record("expected .plan"); return }
    #expect(draft.unassigned.isEmpty)
    #expect(draft.rationale.isEmpty)
}

// MARK: - sanitized(allowedDates:)

@Test func sanitizedDemotesOutOfRangeDays() {
    let draft = PlanDraft(
        days: [
            PlanDay(date: "2026-07-16", tasks: [PlanTask(title: "in range", note: nil)]),
            PlanDay(date: "2026-08-01", tasks: [
                PlanTask(title: "out A", note: nil),
                PlanTask(title: "out B", note: "n"),
            ]),
        ],
        unassigned: ["already out"],
        rationale: "r"
    )
    let s = draft.sanitized(allowedDates: ["2026-07-16"])
    #expect(s.days.count == 1)
    #expect(s.days[0].date == "2026-07-16")
    #expect(s.unassigned == ["already out", "out A", "out B"])
    #expect(s.rationale == "r")
}

@Test func sanitizedKeepsInRangeUntouched() {
    let draft = PlanDraft(
        days: [PlanDay(date: "2026-07-16", tasks: [PlanTask(title: "t", note: nil)])],
        unassigned: [],
        rationale: ""
    )
    let s = draft.sanitized(allowedDates: ["2026-07-16", "2026-07-17"])
    #expect(s == draft)
}
