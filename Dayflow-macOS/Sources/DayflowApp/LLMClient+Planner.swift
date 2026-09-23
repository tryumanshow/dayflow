import Foundation

/// One turn in the planner conversation. The planner keeps its own light
/// message type instead of provider dicts so `PlannerEngine` stays
/// provider-agnostic.
struct PlannerMessage {
    enum Role: String {
        case user
        case assistant
    }
    let role: Role
    let text: String
}

extension LLMClient {
    /// Shared JSON schema for the planner union response. Both providers
    /// get the same shape: Anthropic as a forced tool's `input_schema`,
    /// OpenAI as `response_format.json_schema`.
    static let plannerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "status": ["type": "string", "enum": ["questions", "plan"]],
            "questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "options": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["text"],
                ],
            ],
            "days": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string"],
                        "tasks": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string"],
                                    "note": ["type": "string"],
                                ],
                                "required": ["title"],
                            ],
                        ],
                    ],
                    "required": ["date", "tasks"],
                ],
            ],
            "unassigned": ["type": "array", "items": ["type": "string"]],
            "rationale": ["type": "string"],
        ],
        "required": ["status"],
    ]

    /// Run one planner turn against the configured provider and parse the
    /// structured reply. On a malformed reply, retries once with the parse
    /// error appended so the model can correct itself; a second failure
    /// surfaces as `LLMError.decodeFailed`.
    func plannerTurn(system: String, messages: [PlannerMessage]) async throws -> PlannerResponse {
        let provider = LLMConfigStore.activeProvider
        guard let apiKey = LLMConfigStore.apiKey(for: provider) else {
            throw LLMError.missingAPIKey(provider)
        }
        let model = LLMConfigStore.model(for: provider)

        let json = try await plannerRawTurn(
            provider: provider, apiKey: apiKey, model: model,
            system: system, messages: messages
        )
        do {
            return try PlannerResponse.decode(fromJSON: json)
        } catch {
            var retryMessages = messages
            retryMessages.append(PlannerMessage(role: .assistant, text: json))
            retryMessages.append(PlannerMessage(
                role: .user,
                text: "Your previous reply was not valid against the required schema (\(error)). Reply again with ONLY a valid JSON object."
            ))
            let retried = try await plannerRawTurn(
                provider: provider, apiKey: apiKey, model: model,
                system: system, messages: retryMessages
            )
            guard let response = try? PlannerResponse.decode(fromJSON: retried) else {
                throw LLMError.decodeFailed
            }
            return response
        }
    }

    private func plannerRawTurn(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        system: String,
        messages: [PlannerMessage]
    ) async throws -> String {
        switch provider {
        case .anthropic:
            return try await plannerCallAnthropic(apiKey: apiKey, model: model, system: system, messages: messages)
        case .openai:
            return try await plannerCallOpenAI(apiKey: apiKey, model: model, system: system, messages: messages)
        }
    }

    // MARK: Anthropic — forced tool use

    private func plannerCallAnthropic(
        apiKey: String, model: String, system: String, messages: [PlannerMessage]
    ) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "tools": [[
                "name": "plan_response",
                "description": "Return either clarifying questions or the final plan.",
                "input_schema": Self.plannerSchema,
            ]],
            "tool_choice": ["type": "tool", "name": "plan_response"],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMError.decodeFailed }
        if http.statusCode != 200 {
            throw LLMError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "", endpoint)
        }
        return try Self.plannerJSON(fromAnthropicData: data)
    }

    /// Pull the forced tool call's input object back out as JSON text.
    static func plannerJSON(fromAnthropicData data: Data) throws -> String {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]],
            let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
            let input = toolUse["input"],
            JSONSerialization.isValidJSONObject(input),
            let text = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)
        else {
            throw LLMError.decodeFailed
        }
        return text
    }

    // MARK: OpenAI — json_schema response format

    private func plannerCallOpenAI(
        apiKey: String, model: String, system: String, messages: [PlannerMessage]
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var allMessages: [[String: Any]] = [["role": "system", "content": system]]
        allMessages.append(contentsOf: messages.map { ["role": $0.role.rawValue, "content": $0.text] })
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": allMessages,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "plan_response", "schema": Self.plannerSchema],
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMError.decodeFailed }
        if http.statusCode != 200 {
            throw LLMError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "", url)
        }
        return try Self.plannerJSON(fromOpenAIData: data)
    }

    /// Pull the assistant message content back out as JSON text.
    static func plannerJSON(fromOpenAIData data: Data) throws -> String {
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard
            let reply = try? JSONDecoder().decode(Reply.self, from: data),
            let content = reply.choices.first?.message.content,
            !content.isEmpty
        else {
            throw LLMError.decodeFailed
        }
        return content
    }
}
