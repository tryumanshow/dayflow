import Foundation

/// Minimal Anthropic Messages API client for the daily-review feature.
///
/// Uses ANTHROPIC_API_KEY from the user's environment. The key is read once
/// at process start (LaunchAgent inherits the login shell env in most setups;
/// failing that, the user can `launchctl setenv ANTHROPIC_API_KEY ...`).
struct AnthropicClient {
    static let shared = AnthropicClient()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model: String

    init(model: String = "claude-sonnet-4-5") {
        if let envModel = ProcessInfo.processInfo.environment["DAYFLOW_REVIEW_MODEL"], !envModel.isEmpty {
            self.model = envModel
        } else {
            self.model = model
        }
    }

    enum AnthropicError: Error, LocalizedError {
        case missingAPIKey
        case badResponse(Int, String)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "ANTHROPIC_API_KEY 가 설정 안 돼있어. 터미널에서 `launchctl setenv ANTHROPIC_API_KEY sk-...` 후 앱 재시작."
            case .badResponse(let code, let body):
                return "Anthropic API \(code): \(body.prefix(200))"
            case .decodeFailed:
                return "Anthropic 응답 해석 실패"
            }
        }
    }

    private static let systemPrompt = """
    너는 사용자의 일일 회고를 돕는 어시스턴트야. \
    한국어 반말 톤으로 간결하게 답해. \
    출력은 마크다운 한 덩어리로, 다음 3개 섹션을 정확히 이 순서로 써:
    1. **잘 한 것** — 오늘 끝낸 task / 진척 (불릿 2~4개)
    2. **막힌 것** — 시작했지만 끝내지 못한 부분, 메모에 드러난 어려움 (불릿 1~3개)
    3. **내일 우선순위 3가지** — 남은 TODO 와 맥락을 고려해서 1-2-3 번호로
    예의차림 / 인사 / 사족 금지. 본문만.
    """

    func dailyReview(payload: [String: Any]) async throws -> String {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            throw AnthropicError.missingAPIKey
        }

        let snapshotJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            snapshotJSON = s
        } else {
            snapshotJSON = "{}"
        }

        let userText = "오늘 데이터를 바탕으로 회고를 써줘:\n\n```json\n\(snapshotJSON)\n```"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": userText],
            ],
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.decodeFailed
        }
        if http.statusCode != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.badResponse(http.statusCode, bodyText)
        }

        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw AnthropicError.decodeFailed
        }
        let parts = reply.content.compactMap { $0.text }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "(빈 응답)" : joined
    }
}
