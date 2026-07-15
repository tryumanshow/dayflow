import Testing
import Foundation
@testable import DayflowApp

// Provider response → JSON text extraction. The network call itself is not
// unit-tested (same policy as dailyReview); these cover the parsing seams.

@Test func extractsAnthropicToolUseInput() throws {
    let fixture = """
        {"content":[
          {"type":"text","text":"thinking..."},
          {"type":"tool_use","name":"plan_response",
           "input":{"status":"plan","days":[],"unassigned":[],"rationale":"r"}}
        ]}
        """
    let json = try LLMClient.plannerJSON(fromAnthropicData: Data(fixture.utf8))
    let r = try PlannerResponse.decode(fromJSON: json)
    guard case let .plan(draft) = r else { Issue.record("expected .plan"); return }
    #expect(draft.rationale == "r")
}

@Test func anthropicWithoutToolUseThrows() {
    let fixture = #"{"content":[{"type":"text","text":"no tool call"}]}"#
    #expect(throws: (any Error).self) {
        _ = try LLMClient.plannerJSON(fromAnthropicData: Data(fixture.utf8))
    }
}

@Test func extractsOpenAIMessageContent() throws {
    let inner = #"{\"status\":\"questions\",\"questions\":[{\"text\":\"which?\"}]}"#
    let fixture = """
        {"choices":[{"message":{"content":"\(inner)"}}]}
        """
    let json = try LLMClient.plannerJSON(fromOpenAIData: Data(fixture.utf8))
    let r = try PlannerResponse.decode(fromJSON: json)
    guard case let .questions(qs) = r else { Issue.record("expected .questions"); return }
    #expect(qs.first?.text == "which?")
}

@Test func openAIEmptyChoicesThrows() {
    let fixture = #"{"choices":[]}"#
    #expect(throws: (any Error).self) {
        _ = try LLMClient.plannerJSON(fromOpenAIData: Data(fixture.utf8))
    }
}
