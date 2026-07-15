import Testing
import Foundation
@testable import DayflowApp

private let label = "generated 7/15"

private func task(_ title: String, _ note: String? = nil) -> PlanTask {
    PlanTask(title: title, note: note)
}

// MARK: - render

@Test func renderProducesHeadingAndTasks() {
    let md = PlanMarkdown.render(
        tasks: [task("write post", "vLLM"), task("resume")],
        carriedDone: [],
        generatedLabel: label
    )
    let lines = md.components(separatedBy: "\n")
    #expect(lines[0] == "## 📋 Plan (generated 7/15)")
    #expect(lines.contains("- [ ] write post — vLLM"))
    #expect(lines.contains("- [ ] resume"))
}

@Test func renderKeepsCarriedDoneOnTop() {
    let md = PlanMarkdown.render(
        tasks: [task("new task")],
        carriedDone: ["old finished"],
        generatedLabel: label
    )
    let lines = md.components(separatedBy: "\n")
    let doneIdx = lines.firstIndex(of: "- [x] old finished")
    let newIdx = lines.firstIndex(of: "- [ ] new task")
    #expect(doneIdx != nil && newIdx != nil)
    #expect(doneIdx! < newIdx!)
}

// MARK: - apply: append

@Test func applyAppendsToEmptyBody() {
    let out = PlanMarkdown.apply(tasks: [task("t1")], to: "", generatedLabel: label)
    #expect(out.hasPrefix("## 📋 Plan"))
    #expect(out.contains("- [ ] t1"))
}

@Test func applyAppendsAfterExistingContentWithBlankLine() {
    let body = "# my day\n- [ ] hand-written"
    let out = PlanMarkdown.apply(tasks: [task("t1")], to: body, generatedLabel: label)
    #expect(out.hasPrefix("# my day\n- [ ] hand-written\n\n## 📋 Plan"))
    #expect(out.contains("- [ ] t1"))
}

// MARK: - apply: replace

@Test func applyReplacesExistingSectionPreservingChecked() {
    let body = """
        # my day
        - [ ] hand-written

        ## 📋 Plan (generated 7/14)
        - [x] finished yesterday
        - [ ] stale unfinished
        """
    let out = PlanMarkdown.apply(tasks: [task("fresh")], to: body, generatedLabel: label)
    #expect(out.contains("- [ ] hand-written"))
    #expect(out.contains("(generated 7/15)"))
    #expect(!out.contains("(generated 7/14)"))
    #expect(out.contains("- [x] finished yesterday"))
    #expect(!out.contains("stale unfinished"))
    #expect(out.contains("- [ ] fresh"))
    // exactly one plan heading remains
    let headings = out.components(separatedBy: "\n").filter { $0.hasPrefix("## 📋 Plan") }
    #expect(headings.count == 1)
}

@Test func applyRespectsSectionBoundaryAtNextHeading() {
    let body = """
        ## 📋 Plan (generated 7/14)
        - [ ] stale

        ## notes
        untouchable content
        """
    let out = PlanMarkdown.apply(tasks: [task("fresh")], to: body, generatedLabel: label)
    #expect(out.contains("## notes"))
    #expect(out.contains("untouchable content"))
    #expect(!out.contains("- [ ] stale"))
    #expect(out.contains("- [ ] fresh"))
}

@Test func applyToleratesBlockNoteStarBullets() {
    // BlockNote emits `*   [x] foo`; detection must not miss those.
    let body = """
        ## 📋 Plan (generated 7/14)
        *   [x] done blocknote style
        *   [ ] stale
        """
    let out = PlanMarkdown.apply(tasks: [task("fresh")], to: body, generatedLabel: label)
    #expect(out.contains("- [x] done blocknote style"))
    #expect(!out.contains("stale"))
}

@Test func applyLeavesBodyWithoutSectionUntouchedElsewhere() {
    let body = "plain paragraph\n- [x] done by hand"
    let out = PlanMarkdown.apply(tasks: [task("t")], to: body, generatedLabel: label)
    #expect(out.hasPrefix("plain paragraph\n- [x] done by hand"))
}
