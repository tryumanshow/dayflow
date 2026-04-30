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
                    NotificationCenter.default.post(name: .dayflowCopy, object: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Cut") {
                    NotificationCenter.default.post(name: .dayflowCut, object: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                Button("Paste") {
                    NotificationCenter.default.post(name: .dayflowPaste, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Select All") {
                    NotificationCenter.default.post(name: .dayflowSelectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .dayflowUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    NotificationCenter.default.post(name: .dayflowRedo, object: nil)
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
