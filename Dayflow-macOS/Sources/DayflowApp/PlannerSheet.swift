import SwiftUI

/// Presentation token for `.sheet(item:)` — same rationale as
/// `CarryoverBatch`: the item form hands the prefilled range to the sheet
/// in the same transaction that presents it.
struct PlannerRequest: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
}

/// The AI planner: task dump + date range in, per-day checklist plan out.
/// Three content phases — input → (questions →) preview. The LLM may ask up
/// to `PlannerEngine.maxQuestionRounds` rounds of clarifying questions; the
/// user can always skip them, and refine the plan with feedback in preview.
///
/// A network / decode failure never destroys the conversation: it surfaces
/// as a dismissible banner over the current phase with a Retry that re-runs
/// the failed turn (the engine is transactional, so retry resumes cleanly).
@MainActor
struct PlannerSheet: View {
    let store: DayflowStore
    let onClose: () -> Void

    @State private var taskDump: String = ""
    @State private var start: Date
    @State private var end: Date
    @State private var phase: Phase = .input
    @State private var engine: PlannerEngine?
    @State private var answerDrafts: [String] = []
    @State private var feedbackDraft: String = ""

    /// A turn is in flight — dims the content and shows a spinner, but the
    /// underlying phase (questions/preview) stays put.
    @State private var inFlight = false
    /// Last turn's error, shown as a banner. Cleared on the next attempt.
    @State private var errorBanner: String?
    /// The turn to re-run when the user taps Retry. Set on every attempt so
    /// Retry repeats exactly what failed.
    @State private var lastTurn: (() async throws -> PlannerResponse?)?

    enum Phase {
        case input
        case questions([PlanQuestion])
        case preview(PlanDraft, replacing: Set<String>)
    }

    init(store: DayflowStore, defaultStart: Date, defaultEnd: Date, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _start = State(initialValue: defaultStart)
        _end = State(initialValue: defaultEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.dfAccent)
                Text(L("planner.title"))
                    .font(.headline)
                Spacer()
                if inFlight {
                    ProgressView().controlSize(.small)
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            if let errorBanner {
                errorBannerView(errorBanner)
            }

            Group {
                switch phase {
                case .input:                          inputPhase
                case .questions(let qs):              questionsPhase(qs)
                case .preview(let draft, let badges): previewPhase(draft, replacing: badges)
                }
            }
            .disabled(inFlight)
            .opacity(inFlight ? 0.5 : 1)
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Non-destructive error surface: the conversation is intact underneath.
    private func errorBannerView(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: DS.Space.sm)
            if lastTurn != nil {
                Button(L("planner.retry")) { retry() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dfAccent)
                    .disabled(inFlight)
            }
            Button {
                errorBanner = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - input

    private var inputPhase: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("planner.hint"))
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $taskDump)
                .font(DS.FontStyle.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.primary.opacity(0.04)))
                .overlay(alignment: .topLeading) {
                    if taskDump.isEmpty {
                        Text(L("planner.dump_placeholder"))
                            .font(DS.FontStyle.body)
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: DS.Space.lg) {
                DatePicker(L("planner.start"), selection: $start, displayedComponents: .date)
                DatePicker(L("planner.end"), selection: $end, in: start..., displayedComponents: .date)
            }
            .datePickerStyle(.compact)

            HStack {
                Spacer()
                Button(L("planner.generate")) { generate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(taskDump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - questions

    private func questionsPhase(_ questions: [PlanQuestion]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("planner.questions_hint"))
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { idx, q in
                        questionCard(q, index: idx)
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Button(L("planner.skip")) {
                    perform { try await self.engine?.forcePlan() }
                }
                .buttonStyle(.plain)
                .font(DS.FontStyle.caption)
                .foregroundStyle(Color.dfAccent)
                .disabled(inFlight)
                Spacer()
                Button(L("planner.answer")) {
                    let answers = answerDrafts
                    perform { try await self.engine?.submitAnswers(answers) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inFlight || answerDrafts.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
    }

    private func questionCard(_ q: PlanQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(q.text)
                .font(DS.FontStyle.body)
            if let options = q.options, !options.isEmpty {
                HStack(spacing: DS.Space.sm) {
                    ForEach(options, id: \.self) { option in
                        let isPicked = answerDrafts[safe: index] == option
                        Button(option) {
                            if index < answerDrafts.count { answerDrafts[index] = option }
                        }
                        .buttonStyle(.plain)
                        .font(DS.FontStyle.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isPicked ? Color.dfAccent.opacity(0.25) : Color.primary.opacity(0.06)))
                        .foregroundStyle(isPicked ? Color.dfAccent : .primary)
                    }
                }
            }
            TextField(L("planner.answer_placeholder"), text: answerBinding(index))
                .textFieldStyle(.roundedBorder)
                .font(DS.FontStyle.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.primary.opacity(0.04)))
    }

    private func answerBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { answerDrafts[safe: index] ?? "" },
            set: { if index < answerDrafts.count { answerDrafts[index] = $0 } }
        )
    }

    // MARK: - preview

    private func previewPhase(_ draft: PlanDraft, replacing: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(draft.days, id: \.date) { day in
                        dayCard(day, willReplace: replacing.contains(day.date))
                    }
                    if !draft.unassigned.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("planner.unassigned"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(draft.unassigned, id: \.self) { item in
                                Text("· \(item)")
                                    .font(DS.FontStyle.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 340)

            if !draft.rationale.isEmpty {
                Text(draft.rationale)
                    .font(DS.FontStyle.micro)
                    .foregroundStyle(.tertiary)
            }

            // Revision loop: free-form feedback re-enters the same
            // conversation, so "move the blog post earlier" is understood
            // against the plan the model just produced. Multi-line + soft
            // wrap so long feedback doesn't run off the edge — Return makes
            // a newline, the button (or ⌘↵) submits.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                TextEditor(text: $feedbackDraft)
                    .font(DS.FontStyle.caption)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.primary.opacity(0.04)))
                    .overlay(alignment: .topLeading) {
                        if feedbackDraft.isEmpty {
                            Text(L("planner.feedback_placeholder"))
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Button(L("planner.revise")) { revise() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(inFlight || feedbackDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Button(L("planner.back")) { phase = .input }
                    .buttonStyle(.plain)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(Color.dfAccent)
                Spacer()
                Button(L("planner.apply")) {
                    store.applyPlan(draft)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inFlight || draft.days.isEmpty)
            }
        }
    }

    private func revise() {
        let feedback = feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { return }
        feedbackDraft = ""
        perform { try await self.engine?.revise(feedback) }
    }

    private func dayCard(_ day: PlanDay, willReplace: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayLabel(day.date))
                    .font(.system(size: 12, weight: .semibold))
                if willReplace {
                    Text(L("planner.replace_badge"))
                        .font(DS.FontStyle.micro)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
            }
            ForEach(Array(day.tasks.enumerated()), id: \.offset) { _, task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(DS.FontStyle.body)
                        if let note = task.note, !note.isEmpty {
                            Text(note)
                                .font(DS.FontStyle.micro)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.primary.opacity(0.04)))
    }

    private func dayLabel(_ ymd: String) -> String {
        guard let date = DF.ymd.date(from: ymd) else { return ymd }
        return DF.shortDate.string(from: date)
    }

    // MARK: - actions

    private func generate() {
        let engine = PlannerEngine(db: store.db, start: start, end: end, taskDump: taskDump)
        self.engine = engine
        perform { try await engine.start() }
    }

    private func retry() {
        guard let turn = lastTurn else { return }
        perform(turn)
    }

    /// Run one engine turn, translating success into a phase transition and
    /// failure into a non-destructive banner. `turn` is retained as
    /// `lastTurn` so Retry re-runs the exact same request; the engine is
    /// transactional, so a retry after a failure resumes rather than
    /// duplicating or discarding the conversation.
    private func perform(_ turn: @escaping () async throws -> PlannerResponse?) {
        lastTurn = turn
        errorBanner = nil
        inFlight = true
        _Concurrency.Task {
            do {
                guard let response = try await turn() else { inFlight = false; return }
                switch response {
                case .questions(let qs):
                    answerDrafts = Array(repeating: "", count: qs.count)
                    phase = .questions(qs)
                case .plan(let draft):
                    let replacing = Set(store.datesWithExistingPlan(in: draft))
                    phase = .preview(draft, replacing: replacing)
                }
                lastTurn = nil       // succeeded — nothing to retry
                inFlight = false
            } catch {
                errorBanner = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                inFlight = false
            }
        }
    }
}
