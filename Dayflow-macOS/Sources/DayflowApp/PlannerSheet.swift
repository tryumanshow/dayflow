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
/// One sheet, five phases — input → loading → (questions →) preview →
/// applied. The LLM may ask up to `PlannerEngine.maxQuestionRounds` rounds
/// of clarifying questions; the user can always skip them.
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

    enum Phase {
        case input
        case loading
        case questions([PlanQuestion])
        case preview(PlanDraft, replacing: Set<String>)
        case error(String)
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

            switch phase {
            case .input:                          inputPhase
            case .loading:                        loadingPhase
            case .questions(let qs):              questionsPhase(qs)
            case .preview(let draft, let badges): previewPhase(draft, replacing: badges)
            case .error(let message):             errorPhase(message)
            }
        }
        .padding(20)
        .frame(width: 520)
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
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.white.opacity(0.04)))
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

    // MARK: - loading

    private var loadingPhase: some View {
        HStack(spacing: DS.Space.sm) {
            ProgressView().controlSize(.small)
            Text(L("planner.loading"))
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
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
                Button(L("planner.skip")) { run { try await self.engine?.forcePlan() } }
                    .buttonStyle(.plain)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(Color.dfAccent)
                Spacer()
                Button(L("planner.answer")) {
                    run { try await self.engine?.submitAnswers(self.answerDrafts) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(answerDrafts.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
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
                        .background(Capsule().fill(isPicked ? Color.dfAccent.opacity(0.25) : Color.white.opacity(0.06)))
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
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.white.opacity(0.04)))
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
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.days.isEmpty)
            }
        }
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
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Color.white.opacity(0.04)))
    }

    private func dayLabel(_ ymd: String) -> String {
        guard let date = DF.ymd.date(from: ymd) else { return ymd }
        return DF.shortDate.string(from: date)
    }

    // MARK: - error

    private func errorPhase(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Label {
                Text(message)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L("planner.back")) { phase = .input }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // MARK: - actions

    private func generate() {
        let engine = PlannerEngine(db: store.db, start: start, end: end, taskDump: taskDump)
        self.engine = engine
        run { try await engine.start() }
    }

    /// Run one engine turn and translate the outcome into a phase.
    private func run(_ turn: @escaping () async throws -> PlannerResponse?) {
        phase = .loading
        _Concurrency.Task {
            do {
                guard let response = try await turn() else { return }
                switch response {
                case .questions(let qs):
                    answerDrafts = Array(repeating: "", count: qs.count)
                    phase = .questions(qs)
                case .plan(let draft):
                    let replacing = Set(store.datesWithExistingPlan(in: draft))
                    phase = .preview(draft, replacing: replacing)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                phase = .error(message)
            }
        }
    }
}
