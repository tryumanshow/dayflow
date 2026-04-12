import SwiftUI
import Security

/// Native Preferences window. The only UI for managing LLM credentials,
/// provider choice, the editable system prompt, and the app language.
///
/// Dayflow talks to one provider at a time (OpenAI or Anthropic). Each
/// provider has its own Keychain slot and its own stored model preference
/// so switching back and forth doesn't clobber anything.
struct SettingsView: View {
    @State private var provider: LLMProvider = LLMConfigStore.activeProvider
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var systemPrompt: String = LLMConfigStore.systemPrompt
    @State private var language: AppLanguage = LanguagePreference.current
    @AppStorage(AppStorageKeys.dayEditorFontSize) private var dayEditorFontSize: Double = AppStorageKeys.dayEditorFontSizeDefault
    @AppStorage(AppStorageKeys.monthPlanEditorFontSize) private var monthPlanEditorFontSize: Double = AppStorageKeys.monthPlanEditorFontSizeDefault
    @AppStorage(AppStorageKeys.holidaysMode) private var holidaysMode: HolidayDisplayMode = .off
    @State private var saved: Bool = false
    @State private var hasExisting: Bool = false
    @State private var errorMessage: String?
    @State private var testResult: String?
    @State private var testing: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L("settings.general_tab"), systemImage: "gearshape") }
            llmTab
                .tabItem { Label(L("settings.llm_tab"), systemImage: "brain") }
        }
        .frame(width: 520, height: 580)
        .onAppear { refresh() }
    }

    @State private var showRestartAlert = false

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(
                label: L("settings.language"),
                hint: L("settings.language.hint")
            ) {
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: language) { _, newValue in
                    LanguagePreference.current = newValue
                    showRestartAlert = true
                }
            }
            .alert(L("settings.language.restart_hint"), isPresented: $showRestartAlert) {
                Button(L("settings.language.restart_now")) {
                    // Relaunch the app
                    let url = URL(fileURLWithPath: Bundle.main.bundlePath)
                    let config = NSWorkspace.OpenConfiguration()
                    config.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: url, configuration: config)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                }
                Button(L("settings.language.restart_later"), role: .cancel) {}
            }

            fontSizeSlider(label: L("settings.editor_font_size.day"),
                           hint: L("settings.editor_font_size.hint"),
                           value: $dayEditorFontSize)
            fontSizeSlider(label: L("settings.editor_font_size.month_plan"),
                           hint: nil,
                           value: $monthPlanEditorFontSize)

            field(
                label: L("settings.holidays"),
                hint: L("settings.holidays.hint")
            ) {
                Picker("", selection: $holidaysMode) {
                    ForEach(HolidayDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Spacer()
        }
        .padding(24)
    }

    private var llmTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            field(label: L("settings.provider")) {
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

            Divider()

            field(
                label: L("settings.api_key"),
                hint: hasExisting ? L("settings.api_key.hint_existing") : nil
            ) {
                SecureField("", text: $apiKey, prompt: Text(placeholderForProvider(provider)))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
            }

            Divider()

            field(label: L("settings.model")) {
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

            Divider()

            field(
                label: L("settings.system_prompt"),
                hint: L("settings.system_prompt.hint")
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
                        Button(L("settings.reset_default")) { resetPrompt() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Spacer()
                        Text(L("settings.char_count", systemPrompt.count))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(L("settings.save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                Button(L("settings.test_connection")) { test() }
                    .buttonStyle(.bordered)
                    .disabled(testing || !canTest)
                if hasExisting {
                    Button(L("settings.delete_key")) { clear() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if testing {
                    ProgressView().controlSize(.small)
                } else if saved {
                    Text(L("settings.saved"))
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
                Link(L("settings.get_api_key"), destination: url)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        }
    }

    // MARK: - subviews

    @ViewBuilder
    private func fontSizeSlider(label: String, hint: String?, value: Binding<Double>) -> some View {
        field(label: label, hint: hint) {
            HStack(spacing: 10) {
                // 9px is the tightest we go — below that BlockNote's
                // heading `em` multipliers collapse headings into body.
                Slider(value: value, in: 9...20, step: 1)
                    .frame(maxWidth: 260)
                Text("\(Int(value.wrappedValue)) px")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
        }
    }

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

    // MARK: - state

    private var canTest: Bool {
        let keyOK = !apiKey.trimmingCharacters(in: .whitespaces).isEmpty || hasExisting
        let modelOK = !model.trimmingCharacters(in: .whitespaces).isEmpty
        return keyOK && modelOK
    }

    private var canSave: Bool {
        let k = apiKey.trimmingCharacters(in: .whitespaces)
        let hasKey = hasExisting || !k.isEmpty
        let hasModel = !model.trimmingCharacters(in: .whitespaces).isEmpty
        let promptChanged = systemPrompt != LLMConfigStore.systemPrompt
        // Allow save if prompt changed (even without key), or key+model are set
        if promptChanged { return true }
        return hasKey && hasModel
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
                errorMessage = L("settings.error.keychain_save", reason, Int(writeStatus))
                return
            }
            guard let readBack = LLMConfigStore.apiKey(for: provider), readBack == trimmedKey else {
                errorMessage = L("settings.error.keychain_readback")
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
            testResult = L("settings.test.no_key")
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
                    let clipped = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    testResult = L("settings.test.ok_format", clipped)
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
