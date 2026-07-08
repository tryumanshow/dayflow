import Foundation

@MainActor
extension DayflowStore {
    // MARK: - month plan sections

    func addMonthPlanSection(title: String) {
        let order = (monthPlanSections.last?.sortOrder ?? -1) + 1
        let newId = db.addMonthPlanSection(date: selectedDate, title: title, sortOrder: order)
        monthPlanSections.append(MonthPlanSection(
            id: newId, title: title, sortOrder: order, bodyMd: "", bodyJSON: nil
        ))
    }

    func updateMonthPlanSection(id: Int64, body: String, bodyJSON: String?) {
        db.updateMonthPlanSection(id: id, body: body, bodyJSON: bodyJSON)
        if let idx = monthPlanSections.firstIndex(where: { $0.id == id }),
           monthPlanSections[idx].bodyMd != body || monthPlanSections[idx].bodyJSON != bodyJSON {
            monthPlanSections[idx].bodyMd = body
            monthPlanSections[idx].bodyJSON = bodyJSON
        }
    }

    func renameMonthPlanSection(id: Int64, title: String) {
        db.renameMonthPlanSection(id: id, title: title)
        if let idx = monthPlanSections.firstIndex(where: { $0.id == id }) {
            monthPlanSections[idx].title = title
        }
    }

    func deleteMonthPlanSection(id: Int64) {
        db.deleteMonthPlanSection(id: id)
        monthPlanSections.removeAll { $0.id == id }
    }

    /// Recovery surface for the per-section history table. Used by the
    /// section "복구..." menu — see DayflowDB.updateMonthPlanSection for
    /// the snapshot policy that populates this list.
    func monthPlanSectionHistory(id: Int64) -> [DayflowDB.MonthPlanSectionHistoryEntry] {
        db.getMonthPlanSectionHistory(sectionId: id)
    }

    /// Fast path for external markdown-only edits (QuickThrow, Week
    /// checkbox toggles). Updates the in-memory cache without the
    /// month-range SQL round-trip that `refresh(force:)` would cost.
    func applyExternalEdit(date: Date, body: String) {
        let key = DayflowDB.ymd(date)
        if bodies[key] != nil {
            bodies[key] = body
        }
        if Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            setDayBuffers(md: body, json: nil, cacheKey: key)
        }
    }

    /// Flip the `[ ]` ↔ `[x]` marker in a single markdown task line,
    /// preserving indentation, bullet char, and all whitespace.
    func toggleTaskMarker(in line: String) -> String {
        var chars = Array(line)
        var i = 0
        // skip leading whitespace
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
        guard i < chars.count, chars[i] == "-" || chars[i] == "*" || chars[i] == "+" else { return line }
        i += 1
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
        guard i + 2 < chars.count, chars[i] == "[" else { return line }
        let markIdx = i + 1
        guard chars[i + 2] == "]" else { return line }
        switch chars[markIdx] {
        case " ":
            chars[markIdx] = "x"
        case "x", "X", "✓":
            chars[markIdx] = " "
        default:
            return line
        }
        return String(chars)
    }
}
