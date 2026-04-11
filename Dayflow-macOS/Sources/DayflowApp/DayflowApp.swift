import SwiftUI

@main
struct DayflowApp: App {
    @State private var store = DayflowStore()

    init() {
        // Hotkey & quick throw panel are wired up after the store exists.
        // We attach in `body`'s onAppear via a small bridge below.
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
    }
}
