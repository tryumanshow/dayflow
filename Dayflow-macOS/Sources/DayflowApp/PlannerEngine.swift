import Foundation

/// Drives one planning conversation: assembles the context payload from the
/// DB, holds the message history across question rounds, and enforces the
/// round cap so the model can't interrogate the user forever.
///
/// Network access goes through `transport`, injected so tests can stub the
/// LLM; the default routes to `LLMClient.plannerTurn`.
@MainActor
final class PlannerEngine {
    /// After this many question rounds, a further `questions` reply is
    /// answered by a forced "plan now" turn instead of reaching the UI.
    static let maxQuestionRounds = 2

    private let db: DayflowDB
    let start: Date
    let end: Date
    private let taskDump: String

    private(set) var questionRoundsUsed = 0
    private var messages: [PlannerMessage] = []
    /// Pending questions from the last `.questions` response, kept so
    /// `submitAnswers` can pair each answer with its question text.
    private var pendingQuestions: [PlanQuestion] = []

    var transport: (String, [PlannerMessage]) async throws -> PlannerResponse = { system, messages in
        try await LLMClient.shared.plannerTurn(system: system, messages: messages)
    }

    init(db: DayflowDB, start: Date, end: Date, taskDump: String) {
        self.db = db
        let cal = Calendar.current
        self.start = cal.startOfDay(for: min(start, end))
        self.end = cal.startOfDay(for: max(start, end))
        self.taskDump = taskDump
    }

    /// `yyyy-MM-dd` keys for every day in [start, end].
    var allowedDates: Set<String> {
        let cal = Calendar.current
        var out: Set<String> = []
        var cursor = start
        while cursor <= end {
            out.insert(DayflowDB.ymd(cursor))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    private var isSingleDay: Bool { allowedDates.count == 1 }

    // MARK: - conversation

    func start() async throws -> PlannerResponse {
        messages = [PlannerMessage(role: .user, text: initialUserPayload())]
        return try await runTurn()
    }

    /// Send the user's answers, paired with the question texts they answer.
    func submitAnswers(_ answers: [String]) async throws -> PlannerResponse {
        var lines: [String] = []
        for (idx, answer) in answers.enumerated() {
            if let q = pendingQuestions[safe: idx] {
                lines.append("Q: \(q.text)\nA: \(answer)")
            } else {
                lines.append(answer)
            }
        }
        messages.append(PlannerMessage(role: .user, text: lines.joined(separator: "\n\n")))
        return try await runTurn()
    }

    /// "Skip" path — the user declined to answer; the model must plan with
    /// reasonable assumptions and disclose them in the rationale.
    func forcePlan() async throws -> PlannerResponse {
        messages.append(PlannerMessage(role: .user, text: Self.forcePlanDirective))
        return try await runTurn(allowQuestions: false)
    }

    /// Revision loop — the user saw a plan in the preview and wants it
    /// changed. Free-form feedback goes in as a user turn on top of the
    /// full history (which includes the delivered plan), and the reply
    /// must be a plan again, not more questions.
    func revise(_ feedback: String) async throws -> PlannerResponse {
        messages.append(PlannerMessage(
            role: .user,
            text: "Feedback on the plan you produced — revise it accordingly and return the full updated plan:\n\(feedback)"
        ))
        return try await runTurn(allowQuestions: false)
    }

    private static let forcePlanDirective =
        "Do not ask any further questions. Produce the best plan you can with the information you have, make reasonable assumptions, and state those assumptions in the rationale."

    private func runTurn(allowQuestions: Bool = true) async throws -> PlannerResponse {
        let response = try await transport(systemPrompt(), messages)
        switch response {
        case .questions(let qs):
            // The model's reply becomes part of the history either way.
            messages.append(PlannerMessage(role: .assistant, text: Self.encodeQuestions(qs)))
            if allowQuestions && questionRoundsUsed < Self.maxQuestionRounds {
                questionRoundsUsed += 1
                pendingQuestions = qs
                return response
            }
            // Cap reached (or questions disallowed): force the plan.
            messages.append(PlannerMessage(role: .user, text: Self.forcePlanDirective))
            let forced = try await transport(systemPrompt(), messages)
            guard case .plan(let draft) = forced else {
                throw LLMClient.LLMError.decodeFailed
            }
            return finish(draft)
        case .plan(let draft):
            return finish(draft)
        }
    }

    private func finish(_ draft: PlanDraft) -> PlannerResponse {
        let sanitized = draft.sanitized(allowedDates: allowedDates)
        // Record the actual plan in the transcript — a later revision turn
        // needs the model to see what it proposed, not a placeholder.
        messages.append(PlannerMessage(role: .assistant, text: sanitized.encodedJSON()))
        pendingQuestions = []
        return .plan(sanitized)
    }

    /// Replay the questions into the transcript so a follow-up turn sees
    /// what was asked.
    private static func encodeQuestions(_ qs: [PlanQuestion]) -> String {
        qs.map { q in
            if let opts = q.options, !opts.isEmpty {
                return "\(q.text) [\(opts.joined(separator: " / "))]"
            }
            return q.text
        }.joined(separator: "\n")
    }

    // MARK: - prompt assembly

    private func systemPrompt() -> String {
        let emphasis = isSingleDay
            ? L("planner.system_prompt.single_day")
            : L("planner.system_prompt.multi_day")
        return L("planner.system_prompt") + "\n" + emphasis
    }

    /// The first user message: the task dump + range, plus appointments as
    /// time constraints. Deliberately nothing else — the plan schedules
    /// exactly what the user typed; the app must not smuggle in old
    /// unfinished tasks or month goals as extra work.
    func initialUserPayload() -> String {
        var sections: [String] = []
        sections.append("## Tasks to schedule\n\(taskDump)")
        sections.append("## Date range\n\(DayflowDB.ymd(start)) to \(DayflowDB.ymd(end)) (inclusive)")

        let appointments = db.getAppointments(start: start, end: end.addingTimeInterval(86_399))
        if !appointments.isEmpty {
            let lines = appointments.map { apt in
                "- \(DayflowDB.ymd(apt.startAt)) \(apt.timeLabel): \(apt.title)"
            }
            sections.append("## Existing appointments (time already taken — constraints only, do not schedule these)\n\(lines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
    }
}
