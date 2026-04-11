import SwiftUI
import Security

/// Native Preferences window. The only UI for managing LLM credentials and
/// provider choice.
///
/// Dayflow talks to one provider at a time (OpenAI or Anthropic). Each
/// provider has its own Keychain slot for the API key and its own stored
/// model preference, so switching back and forth doesn't clobber anything.
struct SettingsView: View {
    @State private var provider: LLMProvider = LLMConfigStore.activeProvider
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var systemPrompt: String = LLMConfigStore.systemPrompt
    @State private var saved: Bool = false
    @State private var hasExisting: Bool = false
    @State private var errorMessage: String?
    @State private var testResult: String?
    @State private var testing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            field(label: "Provider") {
                Picker("", selection: $provider) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, newValue in
                    LLMConfigStore.activeProvider = newValue
                    refresh()
                }
            }

            field(
                label: "API Key",
                hint: hasExisting ? "현재 저장된 키가 있어. 바꾸려면 새 값을 입력해." : nil
            ) {
                SecureField("", text: $apiKey, prompt: Text(placeholderForProvider(provider)))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
            }

            field(label: "Model") {
                Picker("", selection: $model) {
                    ForEach(provider.presetModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                    if !provider.presetModels.contains(model), !model.isEmpty {
                        Text("\(model) (custom)").tag(model)
                    }
                }
                .labelsHidden()
            }

            field(
                label: "System Prompt",
                hint: "일일 회고 Generate 에서 LLM 에게 보내는 지시문. 비워두거나 \"기본값으로 복원\" 을 누르면 내장 프롬프트로 돌아가."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160, maxHeight: 220)
                        .padding(6)
                        .background(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.7)
                        )
                    HStack {
                        Button("기본값으로 복원") { resetPrompt() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Spacer()
                        Text("\(systemPrompt.count) 자")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("저장") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                Button("연결 테스트") { test() }
                    .buttonStyle(.bordered)
                    .disabled(testing || !canTest)
                if hasExisting {
                    Button("키 삭제") { clear() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if testing {
                    ProgressView().controlSize(.small)
                } else if saved {
                    Text("저장됨")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("OK") ? .green : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = apiKeyHelpURL(provider) {
                Link("API 키 발급 받기 →", destination: url)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { refresh() }
    }

    // MARK: - subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM Provider")
                .font(.headline)
            Text("일일 회고 기능에 사용할 모델 제공자를 고를 수 있어. API 키는 macOS Keychain 에 저장돼 — 터미널도 .env 도 필요 없어.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func field<Content: View>(
        label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - actions

    private var canTest: Bool {
        let keyOK = !apiKey.trimmingCharacters(in: .whitespaces).isEmpty || hasExisting
        let modelOK = !model.trimmingCharacters(in: .whitespaces).isEmpty
        return keyOK && modelOK
    }

    private var canSave: Bool {
        let k = apiKey.trimmingCharacters(in: .whitespaces)
        if !hasExisting && k.isEmpty { return false }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func refresh() {
        errorMessage = nil
        testResult = nil
        hasExisting = LLMConfigStore.hasAPIKey(for: provider)
        apiKey = ""
        model = LLMConfigStore.model(for: provider)
        systemPrompt = LLMConfigStore.systemPrompt
    }

    private func resetPrompt() {
        LLMConfigStore.resetSystemPromptToDefault()
        systemPrompt = LLMConfigStore.systemPrompt
    }

    private func save() {
        guard canSave else { return }
        errorMessage = nil

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        if !trimmedKey.isEmpty {
            let writeStatus = LLMConfigStore.setAPIKey(trimmedKey, for: provider)
            guard writeStatus == errSecSuccess else {
                let reason = (SecCopyErrorMessageString(writeStatus, nil) as String?) ?? "unknown"
                errorMessage = "Keychain 저장 실패: \(reason) (OSStatus \(writeStatus)). 시스템 키체인 잠금 상태나 코드사인 ACL 을 확인해."
                return
            }
            guard let readBack = LLMConfigStore.apiKey(for: provider), readBack == trimmedKey else {
                errorMessage = "키가 저장된 것처럼 보이지만 즉시 읽어올 수 없어. 앱을 완전히 종료한 뒤 다시 열어봐."
                return
            }
        }

        LLMConfigStore.activeProvider = provider
        LLMConfigStore.setModel(model.trimmingCharacters(in: .whitespaces), for: provider)
        LLMConfigStore.systemPrompt = systemPrompt

        withAnimation { saved = true }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { saved = false }
        }
    }

    private func clear() {
        LLMConfigStore.deleteAPIKey(for: provider)
        refresh()
    }

    private func test() {
        errorMessage = nil
        testResult = nil

        let typed = apiKey.trimmingCharacters(in: .whitespaces)
        let keyToUse: String
        if !typed.isEmpty {
            keyToUse = typed
        } else if let stored = LLMConfigStore.apiKey(for: provider) {
            keyToUse = stored
        } else {
            testResult = "키가 없어서 테스트 못 해."
            return
        }

        let modelToUse = model.trimmingCharacters(in: .whitespaces)
        let snapshotProvider = provider

        testing = true
        _Concurrency.Task {
            do {
                let reply = try await LLMClient.shared.testConnection(
                    provider: snapshotProvider,
                    apiKey: keyToUse,
                    model: modelToUse
                )
                await MainActor.run {
                    testing = false
                    let clipped = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                    testResult = "OK · 응답: \(clipped)"
                }
            } catch {
                await MainActor.run {
                    testing = false
                    let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    testResult = desc
                }
            }
        }
    }

    private func placeholderForProvider(_ p: LLMProvider) -> String {
        switch p {
        case .openai:    return "sk-..."
        case .anthropic: return "sk-ant-..."
        }
    }

    private func apiKeyHelpURL(_ p: LLMProvider) -> URL? {
        switch p {
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        }
    }
}
