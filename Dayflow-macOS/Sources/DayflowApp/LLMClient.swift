import Foundation
import Security

/// Supported LLM providers for the daily review feature.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case openai
    case anthropic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// Preset models shown in the settings picker.
    var presetModels: [String] {
        switch self {
        case .openai:
            return ["gpt-4o", "gpt-4o-mini", "o1", "o1-mini", "o3-mini"]
        case .anthropic:
            return [
                "claude-opus-4-6",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-sonnet-4-5",
            ]
        }
    }

    var defaultModel: String { presetModels.first ?? "" }
}

// MARK: - Keychain-backed config store ----------------------------------------

/// Persists provider choice and model in UserDefaults. API keys go into the
/// Keychain, one slot per provider so switching back and forth doesn't
/// clobber credentials.
enum LLMConfigStore {
    private static let providerKey = "dayflow.llm.provider"
    private static let modelKeyPrefix = "dayflow.llm.model."
    private static let keychainService = "dayflow.llm"

    static var activeProvider: LLMProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: providerKey),
               let p = LLMProvider(rawValue: raw) {
                return p
            }
            return .anthropic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    static func model(for provider: LLMProvider) -> String {
        if let stored = UserDefaults.standard.string(forKey: modelKeyPrefix + provider.rawValue),
           !stored.isEmpty {
            return stored
        }
        return provider.defaultModel
    }

    static func setModel(_ model: String, for provider: LLMProvider) {
        UserDefaults.standard.set(model, forKey: modelKeyPrefix + provider.rawValue)
    }

    /// User-editable system prompt. Persisted in UserDefaults; falls back
    /// to `LLMClient.defaultSystemPrompt` when unset. Shared across
    /// providers — the prompt is model-agnostic.
    private static let systemPromptKey = "dayflow.llm.systemPrompt"
    static var systemPrompt: String {
        get {
            let stored = UserDefaults.standard.string(forKey: systemPromptKey)
            if let stored, !stored.isEmpty { return stored }
            return LLMClient.defaultSystemPrompt
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: systemPromptKey)
            }
        }
    }

    static func resetSystemPromptToDefault() {
        UserDefaults.standard.removeObject(forKey: systemPromptKey)
    }

    static func apiKey(for provider: LLMProvider) -> String? {
        if let fromKeychain = keychainRead(account: provider.rawValue), !fromKeychain.isEmpty {
            return fromKeychain
        }
        // Legacy fallback: migrate the old `dayflow.anthropic` / env paths
        // if we just switched to the Anthropic provider.
        if provider == .anthropic {
            if let legacy = keychainRead(service: "dayflow.anthropic", account: "api-key"),
               !legacy.isEmpty {
                setAPIKey(legacy, for: .anthropic)
                return legacy
            }
            if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
               !envKey.isEmpty {
                setAPIKey(envKey, for: .anthropic)
                return envKey
            }
        }
        return nil
    }

    @discardableResult
    static func setAPIKey(_ key: String, for provider: LLMProvider) -> OSStatus {
        keychainWrite(account: provider.rawValue, value: key)
    }

    static func deleteAPIKey(for provider: LLMProvider) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(q as CFDictionary)
    }

    /// Last-write diagnostics — surfaces a human-readable OSStatus from the
    /// most recent `keychainWrite` so the UI can report what went wrong when
    /// a save silently fails (ACL mismatch after a rebuild, locked keychain,
    /// etc.). Cleared on every successful write.
    static private(set) var lastWriteStatus: OSStatus = errSecSuccess

    static func hasAPIKey(for provider: LLMProvider) -> Bool {
        guard let key = apiKey(for: provider) else { return false }
        return !key.isEmpty
    }

    // MARK: internal keychain helpers

    private static func keychainRead(service: String = keychainService, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete-then-add instead of the fragile Update/Add two-step. The
    /// previous version fell into a silent-fail hole whenever `SecItemUpdate`
    /// returned anything other than `errSecSuccess` or `errSecItemNotFound`
    /// (e.g. ACL mismatch after a rebuild of an ad-hoc-signed binary).
    @discardableResult
    private static func keychainWrite(account: String, value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else {
            lastWriteStatus = errSecParam
            return errSecParam
        }
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        lastWriteStatus = status
        return status
    }
}

// MARK: - LLMClient ------------------------------------------------------------

/// One entry point for "generate the daily review". Picks the right provider
/// based on the current config, formats the request, parses the response.
struct LLMClient {
    static let shared = LLMClient()

    enum LLMError: Error, LocalizedError {
        case missingAPIKey(LLMProvider)
        case badResponse(Int, String, URL)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let p):
                return "\(p.label) API 키가 없어. 메뉴 → Dayflow → Settings… 에서 등록해."
            case .badResponse(let code, let body, let url):
                let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
                return "LLM API \(code) at \(url.absoluteString)\n\(snippet)"
            case .decodeFailed:
                return "LLM 응답 해석 실패"
            }
        }
    }

    /// Built-in default. Editable from Settings → System Prompt. The user's
    /// edit is stored in `LLMConfigStore.systemPrompt` and falls back to this
    /// constant on first launch or when the user hits "기본값으로 복원".
    static let defaultSystemPrompt = """
    너는 사용자의 일일 회고를 돕는 어시스턴트야. \
    한국어 반말 톤으로 간결하게 답해. \
    출력은 마크다운 한 덩어리로, 다음 3개 섹션을 정확히 이 순서로 써:
    1. **잘 한 것** — 오늘 끝낸 task / 진척 (불릿 2~4개)
    2. **막힌 것** — 시작했지만 끝내지 못한 부분, 메모에 드러난 어려움 (불릿 1~3개)
    3. **내일 우선순위 3가지** — 남은 TODO 와 맥락을 고려해서 1-2-3 번호로
    예의차림 / 인사 / 사족 금지. 본문만.
    """

    private static let openAIChatURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// Shared provider dispatch — both `testConnection` and `dailyReview`
    /// route through here so the OpenAI endpoint and the provider switch
    /// only live in one place.
    private func dispatch(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        system: String,
        user: String
    ) async throws -> String {
        switch provider {
        case .anthropic:
            return try await callAnthropic(apiKey: apiKey, model: model, system: system, user: user)
        case .openai:
            return try await callOpenAICompatible(url: Self.openAIChatURL, apiKey: apiKey, model: model, system: system, user: user)
        }
    }

    /// Fire a minimal request with the current config without touching the
    /// stored review. Surfaces the same errors as `dailyReview` so the
    /// Settings UI can show whether the provider is reachable.
    func testConnection(
        provider: LLMProvider,
        apiKey: String,
        model: String
    ) async throws -> String {
        try await dispatch(
            provider: provider,
            apiKey: apiKey,
            model: model,
            system: "You are a connectivity test. Respond with the single word: ok",
            user: "ping"
        )
    }

    func dailyReview(payload: [String: Any]) async throws -> String {
        let provider = LLMConfigStore.activeProvider
        guard let apiKey = LLMConfigStore.apiKey(for: provider) else {
            throw LLMError.missingAPIKey(provider)
        }
        let model = LLMConfigStore.model(for: provider)

        let snapshotJSON: String = {
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }()
        let userText = "오늘 데이터를 바탕으로 회고를 써줘:\n\n```json\n\(snapshotJSON)\n```"

        return try await dispatch(
            provider: provider,
            apiKey: apiKey,
            model: model,
            system: LLMConfigStore.systemPrompt,
            user: userText
        )
    }

    // MARK: Anthropic

    private func callAnthropic(apiKey: String, model: String, system: String, user: String) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": user]],
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

        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw LLMError.decodeFailed
        }
        let joined = reply.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "(빈 응답)" : joined
    }

    // MARK: OpenAI

    private func callOpenAICompatible(url: URL, apiKey: String, model: String, system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user],
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

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw LLMError.decodeFailed
        }
        let joined = reply.choices
            .compactMap { $0.message.content }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "(빈 응답)" : joined
    }
}
