import Foundation

@MainActor
extension DayflowStore {
    /// Write each planned day into its note. Days are written
    /// independently — one malformed date doesn't block the rest.
    /// Returns the `yyyy-MM-dd` keys whose existing plan section was
    /// replaced (vs. freshly appended).
    @discardableResult
    func applyPlan(_ draft: PlanDraft) -> [String] {
        let label = L("planner.generated_label", DF.shortMonthDay.string(from: Date()))
        var replaced: [String] = []
        for day in draft.days {
            guard let date = DF.ymd.date(from: day.date) else { continue }
            let body = db.getDayNote(date: date)
            let hadSection = PlanMarkdown.planSectionRange(
                inLines: body.components(separatedBy: "\n")) != nil
            let newBody = PlanMarkdown.apply(tasks: day.tasks, to: body, generatedLabel: label)
            db.saveDayNote(date: date, body: newBody, bodyJSON: nil)
            applyExternalEdit(date: date, body: newBody)
            if hadSection { replaced.append(day.date) }
        }
        return replaced
    }

    /// Which draft days already carry a plan section — drives the
    /// "replaces existing plan" badge in the preview.
    func datesWithExistingPlan(in draft: PlanDraft) -> [String] {
        draft.days.compactMap { day in
            guard let date = DF.ymd.date(from: day.date) else { return nil }
            let lines = db.getDayNote(date: date).components(separatedBy: "\n")
            return PlanMarkdown.planSectionRange(inLines: lines) != nil ? day.date : nil
        }
    }
}
