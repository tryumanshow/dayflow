import Testing
import Foundation
@testable import DayflowApp

// Writers outside the editor (Week-view toggle, carry-over, AI planner) must
// keep `body_json` — and with it colours and underline — in step with the
// markdown they edit, instead of dropping it.

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-json-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func today() -> Date { Calendar.current.startOfDay(for: Date()) }
private func daysAgo(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: today())! }

@MainActor
private func makeStore() -> DayflowStore {
    let store = DayflowStore(db: tempDB())
    store.selectedDate = today()
    return store
}

private func run(_ text: String, _ styles: [String: Any] = [:]) -> [String: Any] {
    ["type": "text", "text": text, "styles": styles]
}

private func node(_ type: String, _ runs: [[String: Any]], props: [String: Any] = [:], children: [[String: Any]] = []) -> [String: Any] {
    ["id": UUID().uuidString, "type": type, "props": props, "content": runs, "children": children]
}

private func json(_ blocks: [[String: Any]]) -> String { BlockNoteJSON.serialize(blocks)! }

private func blocks(_ s: String?) -> [[String: Any]] { BlockNoteJSON.parse(s) ?? [] }

/// Outline of a stored document: `type[status]: text {styles}` per block.
private func outline(_ s: String?) -> String {
    func walk(_ list: [[String: Any]], _ depth: Int) -> String {
        list.map { b in
            let type = BlockNoteJSON.type(b)
            let mark = type == "checkListItem" ? "[\(BlockNoteJSON.status(b))]" : ""
            let styles = ((b["content"] as? [[String: Any]])?.first?["styles"] as? [String: Any] ?? [:])
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return String(repeating: "  ", count: depth) + "\(type)\(mark): \(BlockNoteJSON.text(b))"
                + (styles.isEmpty ? "" : " {\(styles)}") + "\n" + walk(BlockNoteJSON.children(b), depth + 1)
        }.joined()
    }
    // Trailing spaces trimmed so an empty block reads `paragraph:` in the
    // expected strings below.
    return walk(blocks(s), 0).split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        .joined(separator: "\n")
}

// MARK: - Week-view toggle

@MainActor
@Test func weekToggleKeepsTheDaysStyles() {
    let store = makeStore()
    let day = daysAgo(1)
    store.db.saveDayNote(date: day, body: "## Work\n\nred note\n\n*   [ ] ship it\n", bodyJSON: json([
        node("heading", [run("Work")], props: ["level": 2]),
        node("paragraph", [run("red note", ["textColor": "red"])]),
        node("checkListItem", [run("ship it", ["underline": true])], props: ["checked": false]),
    ]))

    store.toggleWeekTask(day: day, sourceLineIndex: 4)

    let full = store.db.getDayNoteFull(date: day)
    #expect(full.body.contains("*   [x] ship it"))
    #expect(outline(full.bodyJSON) == """
        heading: Work
        paragraph: red note {textColor=red}
        checkListItem[done]: ship it {underline=1}

        """)
}

@MainActor
@Test func weekToggleOfOnHoldCompletesAndClearsTheHoldMark() {
    let store = makeStore()
    let day = daysAgo(1)
    store.db.saveDayNote(date: day, body: "*   [~] parked", bodyJSON: json([
        node("checkListItem", [run("parked", ["backgroundColor": "blue"])], props: ["checked": false]),
    ]))

    store.toggleWeekTask(day: day, sourceLineIndex: 0)

    #expect(outline(store.db.getDayNoteFull(date: day).bodyJSON) == "checkListItem[done]: parked\n")
}

/// When markdown and JSON disagree (here JSON has an extra checklist item),
/// the addressed block can't be trusted: markdown-only, as before.
@MainActor
@Test func weekToggleFallsBackToMarkdownOnlyWhenJSONDoesNotLineUp() {
    let store = makeStore()
    let day = daysAgo(1)
    store.db.saveDayNote(date: day, body: "*   [ ] one", bodyJSON: json([
        node("checkListItem", [run("one")], props: ["checked": false]),
        node("checkListItem", [run("two")], props: ["checked": false]),
    ]))

    store.toggleWeekTask(day: day, sourceLineIndex: 0)

    let full = store.db.getDayNoteFull(date: day)
    #expect(full.body == "*   [x] one")
    #expect(full.bodyJSON == nil)
}

// MARK: - carry-over

@MainActor
@Test func carryOverMovesTheStyledBlockAndKeepsBothDaysStyles() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: """
        ## Work

        *   [ ] ship it

            *   sub point

        *   [x] done one

        red note
        """, bodyJSON: json([
            node("heading", [run("Work")], props: ["level": 2]),
            node("checkListItem", [run("ship it", ["textColor": "orange"])], props: ["checked": false],
                 children: [node("bulletListItem", [run("sub point", ["bold": true])])]),
            node("checkListItem", [run("done one")], props: ["checked": true]),
            node("paragraph", [run("red note", ["textColor": "red"])]),
        ]))
    store.db.saveDayNote(date: today(), body: "## Work\n\n*   [x] standup\n\n## Home\n", bodyJSON: json([
        node("heading", [run("Work")], props: ["level": 2]),
        node("checkListItem", [run("standup", ["italic": true])], props: ["checked": true]),
        node("heading", [run("Home")], props: ["level": 2]),
        node("paragraph", []),
    ]))

    store.carryOver(store.pendingCarryovers(into: today()), into: today())

    #expect(outline(store.db.getDayNoteFull(date: daysAgo(1)).bodyJSON) == """
        heading: Work
        checkListItem[done]: done one
        paragraph: red note {textColor=red}

        """)
    #expect(outline(store.db.getDayNoteFull(date: today()).bodyJSON) == """
        heading: Work
        checkListItem[done]: standup {italic=1}
        checkListItem[open]: ship it {textColor=orange}
          bulletListItem: sub point {bold=1}
        heading: Home
        paragraph:

        """)
}

@MainActor
@Test func carryOverIntoBlankDaySeedsHeadingsInTheDocumentToo() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: "## AI\n\n*   [ ] paper\n\n## Macro\n", bodyJSON: json([
        node("heading", [run("AI")], props: ["level": 2]),
        node("checkListItem", [run("paper", ["textColor": "blue"])], props: ["checked": false]),
        node("heading", [run("Macro")], props: ["level": 2]),
    ]))

    store.carryOver(store.pendingCarryovers(into: today()), into: today())

    #expect(outline(store.db.getDayNoteFull(date: today()).bodyJSON) == """
        heading: AI
        checkListItem[open]: paper {textColor=blue}
        heading: Macro

        """)
}

/// A source day saved without JSON has no block to carry: today is written
/// markdown-only rather than with an invented block.
@MainActor
@Test func carryOverFromMarkdownOnlyDayLeavesTodayMarkdownOnly() {
    let store = makeStore()
    store.db.saveDayNote(date: daysAgo(1), body: "- [ ] legacy")
    store.db.saveDayNote(date: today(), body: "*   [x] a", bodyJSON: json([
        node("checkListItem", [run("a", ["textColor": "red"])], props: ["checked": true]),
    ]))

    store.carryOver(store.pendingCarryovers(into: today()), into: today())

    #expect(store.db.getDayNoteFull(date: today()).bodyJSON == nil)
    #expect(store.db.getDayNote(date: today()).contains("- [ ] legacy"))
}

// MARK: - AI planner

@Test func planAppendKeepsExistingStyles() {
    let body = "red note"
    let doc = json([node("paragraph", [run("red note", ["textColor": "red"])])])

    let out = PlanMarkdown.applyToJSON(tasks: [PlanTask(title: "write", note: "30m")], body: body, bodyJSON: doc, generatedLabel: "9/24")

    #expect(outline(out) == """
        paragraph: red note {textColor=red}
        heading: 📋 Plan (9/24)
        checkListItem[open]: write — 30m

        """)
}

@Test func planReplaceKeepsDoneAndOnHoldItemsWithTheirStyles() {
    let body = "## 📋 Plan (old)\n\n*   [x] finished\n\n*   [ ] stale\n\n*   [~] parked\n\n## Notes\n\nkeep"
    let doc = json([
        node("heading", [run("📋 Plan (old)")], props: ["level": 2]),
        node("checkListItem", [run("finished", ["bold": true])], props: ["checked": true]),
        node("checkListItem", [run("stale")], props: ["checked": false]),
        node("checkListItem", [run("parked", ["backgroundColor": "blue"])], props: ["checked": false]),
        node("heading", [run("Notes")], props: ["level": 2]),
        node("paragraph", [run("keep", ["textColor": "green"])]),
    ])

    let out = PlanMarkdown.applyToJSON(tasks: [PlanTask(title: "new", note: nil)], body: body, bodyJSON: doc, generatedLabel: "9/24")

    #expect(outline(out) == """
        heading: 📋 Plan (9/24)
        checkListItem[done]: finished {bold=1}
        checkListItem[onHold]: parked {backgroundColor=blue}
        checkListItem[open]: new
        heading: Notes
        paragraph: keep {textColor=green}

        """)
}
