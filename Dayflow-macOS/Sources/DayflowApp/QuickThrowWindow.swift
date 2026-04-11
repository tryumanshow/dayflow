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

@MainActor
private struct QuickThrowView: View {
    let store: DayflowStore
    let onDone: () -> Void

    @State private var title: String = ""
    @State private var date: Date = Date()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("→ throw a task")
                .font(.headline)
            TextField("e.g. 내일 회의자료 만들기", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
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
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        let v = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { onDone(); return }
        var body = DayflowDB.shared.getDayNote(date: date)
        if !body.isEmpty && !body.hasSuffix("\n") {
            body.append("\n")
        }
        body.append("- [ ] \(v)\n")
        DayflowDB.shared.saveDayNote(date: date, body: body)
        // Hand the new body to the store so the in-memory cache stays in
        // sync with the DB. Cheap path — avoids the month-range SQL query
        // that `refresh(force:)` would re-run on every toss.
        store.applyExternalEdit(date: date, body: body)
        title = ""
        onDone()
    }
}
