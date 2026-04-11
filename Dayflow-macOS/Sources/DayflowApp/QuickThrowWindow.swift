import AppKit
import SwiftUI

/// Lightweight floating panel that pops up on the global hotkey.
///
/// Single text field + date picker. Enter to add, Escape to dismiss. The panel
/// hides itself after submission so the user is back in their previous app
/// instantly.
@MainActor
final class QuickThrowController {
    static let shared = QuickThrowController()

    private var window: NSPanel?
    private weak var store: DayflowStore?

    func attach(store: DayflowStore) {
        self.store = store
    }

    func toggle() {
        if let w = window, w.isVisible {
            close()
            return
        }
        show()
    }

    func show() {
        guard let store else { return }
        if window == nil {
            let host = NSHostingController(rootView: QuickThrowView(store: store, onDone: { [weak self] in
                self?.close()
            }))
            let panel = NSPanel(contentViewController: host)
            panel.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.center()
            self.window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}

private enum QuickThrowKind: String, CaseIterable, Identifiable {
    case task
    case appointment
    var id: String { rawValue }
    var label: String {
        switch self {
        case .task:        return "Task"
        case .appointment: return "Appointment"
        }
    }
}

@MainActor
private struct QuickThrowView: View {
    let store: DayflowStore
    let onDone: () -> Void

    @State private var kind: QuickThrowKind = .task
    @State private var title: String = ""
    @State private var date: Date = Date()
    @State private var timeInput: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(QuickThrowKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                if kind == .appointment {
                    TextField("HH:MM", text: $timeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .monospacedDigit()
                }
                TextField(kind == .task ? "e.g. draft tomorrow's meeting notes"
                                        : "e.g. Lunch with Jane",
                          text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            }

            DatePicker("on", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.compact)

            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func submit() {
        let v = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { onDone(); return }
        switch kind {
        case .task:
            var body = DayflowDB.shared.getDayNote(date: date)
            if !body.isEmpty && !body.hasSuffix("\n") {
                body.append("\n")
            }
            body.append("- [ ] \(v)\n")
            DayflowDB.shared.saveDayNote(date: date, body: body)
            store.applyExternalEdit(date: date, body: body)
        case .appointment:
            let ok = store.addAppointment(on: date, hhmm: timeInput, title: v)
            guard ok else { return }  // bad time — leave dialog open
        }
        title = ""
        timeInput = ""
        onDone()
    }
}
