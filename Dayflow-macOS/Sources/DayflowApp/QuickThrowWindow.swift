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
        // Recreate the panel each time so @State resets (date = today)
        window?.orderOut(nil)
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
            Text(L("quick_throw.title"))
                .font(.headline)
            TextField(L("quick_throw.placeholder"), text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            DatePicker(L("quick_throw.on"), selection: $date, displayedComponents: [.date])
                .datePickerStyle(.compact)
            HStack {
                Spacer()
                Button(L("quick_throw.cancel")) { onDone() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L("quick_throw.add")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            focused = true
            date = Date()
        }
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
