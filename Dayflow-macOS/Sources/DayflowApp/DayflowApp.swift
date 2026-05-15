import SwiftUI

@main
@MainActor
struct DayflowApp: App {
    @State private var store = DayflowStore()

    init() {
        // Apply the stored language override BEFORE any SwiftUI body runs,
        // so `L()` / `DayflowL10n.activeBundle` pick the right strings on
        // the first render. macOS resolves `AppleLanguages` lazily when
        // the bundle is first touched.
        LanguagePreference.applyAtStartup()
    }

    var body: some Scene {
        WindowGroup("dayflow") {
            ContentView()
                .environment(store)
                .onAppear {
                    QuickThrowController.shared.attach(store: store)
                    GlobalHotkey.shared.register {
                        QuickThrowController.shared.toggle()
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Quick Throw…") {
                    QuickThrowController.shared.show()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            // Replace SwiftUI's default Edit-menu pasteboard & undo
            // commands with custom versions that forward to the
            // WKWebView editor via NotificationCenter.
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    if !NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .dayflowCopy, object: nil)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Cut") {
                    if !NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .dayflowCut, object: nil)
                    }
                }
                .keyboardShortcut("x", modifiers: .command)
                Button("Paste") {
                    if !NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .dayflowPaste, object: nil)
                    }
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Select All") {
                    if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .dayflowSelectAll, object: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if !NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .dayflowUndo, object: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if !NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .dayflowRedo, object: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    NotificationCenter.default.post(name: .dayflowFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            // Editor zoom — Cmd+= (also fires for Cmd++), Cmd+-, Cmd+0.
            // Lives in the View menu so it sits next to the standard
            // macOS zoom slot. Active view mode decides which AppStorage
            // value gets bumped (Day rail vs Month plan editor).
            // View-bar navigation commands. Surfacing them in the menu bar
            // does two jobs: discoverability (users see the shortcuts next
            // to the labels) and reach (the shortcuts work app-wide even
            // when the nav bar is offscreen behind a sheet).
            CommandGroup(after: .toolbar) {
                Button(NSLocalizedString("menu.previous", bundle: DayflowL10n.activeBundle, comment: "")) {
                    store.step(by: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                Button(NSLocalizedString("menu.next", bundle: DayflowL10n.activeBundle, comment: "")) {
                    store.step(by: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                Button(NSLocalizedString("menu.today", bundle: DayflowL10n.activeBundle, comment: "")) {
                    store.goToToday()
                }
                .keyboardShortcut("t", modifiers: .command)
                Button(NSLocalizedString("menu.toggle_side_panel", bundle: DayflowL10n.activeBundle, comment: "")) {
                    let key = AppStorageKeys.sideRailHidden
                    let current = UserDefaults.standard.bool(forKey: key)
                    UserDefaults.standard.set(!current, forKey: key)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Button("Editor: Zoom In") {
                    NotificationCenter.default.post(name: .dayflowZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Editor: Zoom Out") {
                    NotificationCenter.default.post(name: .dayflowZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Editor: Default Zoom") {
                    NotificationCenter.default.post(name: .dayflowZoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Generate Daily Review") { store.generateReview() }
                // Developer-only: visible only when a sibling source
                // tree with `build.sh` is detected. End-user installs
                // never see the item.
                if DevRebuild.repoPath != nil {
                    Divider()
                    Button("🔄 Rebuild & Relaunch") { DevRebuild.rebuildAndRelaunch() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }

        MenuBarExtra {
            ContentView()
                .environment(store)
                .frame(width: 1100, height: 700)
        } label: {
            Text(store.menuBarText)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
