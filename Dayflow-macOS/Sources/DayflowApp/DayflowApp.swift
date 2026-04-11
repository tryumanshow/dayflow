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
            CommandGroup(after: .appInfo) {
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Generate Daily Review") { store.generateReview() }
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
