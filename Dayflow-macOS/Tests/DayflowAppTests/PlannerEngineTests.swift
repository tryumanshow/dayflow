import Testing
import Foundation
@testable import DayflowApp

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-planner-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func day(_ offset: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: offset,
                          to: Calendar.current.startOfDay(for: Date()))!
}

@MainActor
private func makeEngine(db: DayflowDB = tempDB(),
                        start: Date = day(0),
                        end: Date = day(2),
                        dump: String = "write blog post\nrewrite resume") -> PlannerEngine {
    PlannerEngine(db: db, start: start, end: end, taskDump: dump)
}

// MARK: - allowed dates

@MainActor
@Test func allowedDatesCoversInclusiveRange() {
    let engine = makeEngine(start: day(0), end: day(2))
    #expect(engine.allowedDates.count == 3)
    #expect(engine.allowedDates.contains(DayflowDB.ymd(day(0))))
    #expect(engine.allowedDates.contains(DayflowDB.ymd(day(2))))
    #expect(!engine.allowedDates.contains(DayflowDB.ymd(day(3))))
}

// MARK: - payload assembly

@MainActor
@Test func payloadContainsOnlyDumpRangeAndAppointments() {
    let db = tempDB()
    // appointment inside the range — a constraint, so it stays
    _ = db.insertAppointment(startAt: day(1).addingTimeInterval(3600 * 10),
                             endAt: nil, title: "dentist", note: nil,
                             category: .event)
    // old unfinished task and month goal — must NOT leak into the payload:
    // the plan schedules exactly what the user typed
    db.saveDayNote(date: day(-2), body: "- [ ] leftover task")
    _ = db.addMonthPlanSection(date: day(0), title: "Career", sortOrder: 0)
    let sections = db.getMonthPlanSections(date: day(0))
    if let s = sections.first {
        db.updateMonthPlanSection(id: s.id, body: "- [ ] monthly goal", bodyJSON: nil)
    }

    let engine = makeEngine(db: db)
    let payload = engine.initialUserPayload()

    #expect(payload.contains("write blog post"))
    #expect(payload.contains(DayflowDB.ymd(day(0))))
    #expect(payload.contains(DayflowDB.ymd(day(2))))
    #expect(payload.contains("dentist"))
    #expect(!payload.contains("leftover task"))
    #expect(!payload.contains("monthly goal"))
}

// MARK: - revision loop

@MainActor
@Test func reviseSendsFeedbackWithPlanHistoryAndReturnsPlan() async throws {
    let engine = makeEngine()
    let first = PlanDraft(
        days: [PlanDay(date: DayflowDB.ymd(day(0)), tasks: [PlanTask(title: "draft v1", note: nil)])],
        unassigned: [], rationale: "v1")
    let second = PlanDraft(days: [], unassigned: [], rationale: "v2")
    var sawFeedback = false
    var historyHadPlanJSON = false
    engine.transport = { _, messages in
        if let last = messages.last, last.text.contains("blog post first please") {
            sawFeedback = true
            historyHadPlanJSON = messages.contains { $0.role == .assistant && $0.text.contains("draft v1") }
            return .plan(second)
        }
        return .plan(first)
    }

    _ = try await engine.start()
    let r = try await engine.revise("blog post first please")
    guard case let .plan(draft) = r else { Issue.record("expected plan"); return }
    #expect(draft.rationale == "v2")
    #expect(sawFeedback)
    #expect(historyHadPlanJSON)  // the model can see the plan it delivered
}

// MARK: - question round cap

@MainActor
@Test func questionRoundsForcePlanAfterCap() async throws {
    let engine = makeEngine()
    var turnCount = 0
    let questions = PlannerResponse.questions([PlanQuestion(text: "q?", options: nil)])
    let plan = PlannerResponse.plan(PlanDraft(days: [], unassigned: [], rationale: "forced"))
    engine.transport = { _, messages in
        turnCount += 1
        // Keep answering with questions; only a force-plan directive gets a plan.
        if messages.last?.text.contains("Do not ask any further questions") == true {
            return plan
        }
        return questions
    }

    var r = try await engine.start()              // round 1 questions
    guard case .questions = r else { Issue.record("expected questions"); return }
    r = try await engine.submitAnswers(["a1"])    // round 2 questions
    guard case .questions = r else { Issue.record("expected questions"); return }
    // Cap reached: next questions response must be auto-converted to a plan.
    r = try await engine.submitAnswers(["a2"])
    guard case let .plan(draft) = r else { Issue.record("expected forced plan"); return }
    #expect(draft.rationale == "forced")
    #expect(engine.questionRoundsUsed == 2)
    #expect(turnCount == 4)  // start + answer + answer(questions) + forced
}

// MARK: - sanitizing wired in

@MainActor
@Test func planResponsesAreSanitized() async throws {
    let engine = makeEngine(start: day(0), end: day(0))
    let outOfRange = DayflowDB.ymd(day(5))
    engine.transport = { _, _ in
        .plan(PlanDraft(
            days: [PlanDay(date: outOfRange, tasks: [PlanTask(title: "wanderer", note: nil)])],
            unassigned: [], rationale: ""))
    }
    let r = try await engine.start()
    guard case let .plan(draft) = r else { Issue.record("expected plan"); return }
    #expect(draft.days.isEmpty)
    #expect(draft.unassigned == ["wanderer"])
}

// MARK: - skip

@MainActor
@Test func forcePlanSendsDirective() async throws {
    let engine = makeEngine()
    var sawDirective = false
    engine.transport = { _, messages in
        if messages.last?.text.contains("Do not ask any further questions") == true {
            sawDirective = true
            return .plan(PlanDraft(days: [], unassigned: [], rationale: ""))
        }
        return .questions([PlanQuestion(text: "q?", options: nil)])
    }
    _ = try await engine.start()
    let r = try await engine.forcePlan()
    guard case .plan = r else { Issue.record("expected plan"); return }
    #expect(sawDirective)
}
