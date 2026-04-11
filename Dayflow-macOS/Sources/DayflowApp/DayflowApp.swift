import SwiftUI

@main
struct DayflowApp: App {
    @State private var store = DayflowStore()

    var body: some Scene {
        // Main window — visible in dock (Q2=B chosen). Closing the window
        // does not quit the app; the menubar item keeps the process alive.
        WindowGroup("dayflow") {
            ContentView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        // Menubar quick-glance + popover. Same ContentView reused.
        MenuBarExtra {
            ContentView()
                .environment(store)
                .frame(width: 720, height: 520)
        } label: {
            Text(store.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
