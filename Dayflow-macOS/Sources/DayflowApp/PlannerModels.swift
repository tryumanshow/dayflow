import Foundation

// MARK: - Planner data model ---------------------------------------------------

/// One task the LLM placed on a day.
struct PlanTask: Equatable {
    let title: String
    let note: String?
}

/// All tasks the LLM placed on one calendar day.
struct PlanDay: Equatable {
    /// `yyyy-MM-dd`, same key format as `DayflowDB.ymd`.
    let date: String
    let tasks: [PlanTask]
}

/// A complete generated plan.
struct PlanDraft: Equatable {
    var days: [PlanDay]
    /// Tasks the LLM could not (honestly) fit into the requested range.
    var unassigned: [String]
    /// One-line reasoning shown in the preview footer.
    var rationale: String
}

/// A clarifying question the LLM asks before committing to a plan.
struct PlanQuestion: Equatable, Identifiable {
    let text: String
    /// Suggested answers rendered as buttons; nil means free-form only.
    let options: [String]?
    var id: String { text }
}

/// Union of the two shapes a planner turn can return, discriminated by
/// the `status` field in the raw JSON.
enum PlannerResponse: Equatable {
    case questions([PlanQuestion])
    case plan(PlanDraft)
}

// MARK: - decoding ---------------------------------------------------------------

extension PlannerResponse {
    enum DecodeError: Error {
        case notJSON
        case missingStatus
        case emptyQuestions
        case missingDays
    }

    /// Raw mirror of the LLM JSON — every field optional so one decoder
    /// covers both union arms; validation happens after decode.
    private struct Raw: Decodable {
        struct RawQuestion: Decodable {
            let text: String
            let options: [String]?
        }
        struct RawTask: Decodable {
            let title: String
            let note: String?
        }
        struct RawDay: Decodable {
            let date: String
            let tasks: [RawTask]
        }
        let status: String?
        let questions: [RawQuestion]?
        let days: [RawDay]?
        let unassigned: [String]?
        let rationale: String?
    }

    /// Parse an LLM reply into the union. Tolerates a Markdown code fence
    /// around the object — models wrap JSON in ``` fences often enough
    /// that rejecting it would burn a retry on formatting noise.
    static func decode(fromJSON text: String) throws -> PlannerResponse {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body
                .components(separatedBy: "\n")
                .drop(while: { $0.hasPrefix("```") })
                .prefix(while: { !$0.hasPrefix("```") })
                .joined(separator: "\n")
        }
        guard let data = body.data(using: .utf8) else { throw DecodeError.notJSON }
        let raw = try JSONDecoder().decode(Raw.self, from: data)

        switch raw.status {
        case "questions":
            guard let qs = raw.questions, !qs.isEmpty else { throw DecodeError.emptyQuestions }
            return .questions(qs.map { PlanQuestion(text: $0.text, options: $0.options) })
        case "plan":
            guard let days = raw.days else { throw DecodeError.missingDays }
            return .plan(PlanDraft(
                days: days.map { d in
                    PlanDay(date: d.date, tasks: d.tasks.map { PlanTask(title: $0.title, note: $0.note) })
                },
                unassigned: raw.unassigned ?? [],
                rationale: raw.rationale ?? ""
            ))
        default:
            throw DecodeError.missingStatus
        }
    }
}

// MARK: - range sanitizing --------------------------------------------------------

extension PlanDraft {
    /// Defensive pass over LLM output: a day outside the requested range is
    /// dropped and its task titles demoted to `unassigned`, so a
    /// hallucinated date can never write into a note the user didn't ask
    /// to plan.
    func sanitized(allowedDates: Set<String>) -> PlanDraft {
        var kept: [PlanDay] = []
        var demoted: [String] = []
        for day in days {
            if allowedDates.contains(day.date) {
                kept.append(day)
            } else {
                demoted.append(contentsOf: day.tasks.map(\.title))
            }
        }
        return PlanDraft(days: kept, unassigned: unassigned + demoted, rationale: rationale)
    }
}
