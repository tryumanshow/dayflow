import AppKit
import Foundation

/// Developer-only convenience: quit + rebuild + relaunch in one click.
/// The menu item only lights up on a machine that has a Dayflow source
/// tree at a known path — release installs on end-user machines see no
/// menu item, since `repoPath` returns nil.
enum DevRebuild {
    /// Locations we'll probe for `build.sh`. Add more entries here if
    /// you keep the checkout somewhere else.
    static var repoCandidates: [String] {
        [
            "\(NSHomeDirectory())/dayflow/Dayflow-macOS",
            "\(NSHomeDirectory())/Code/dayflow/Dayflow-macOS",
            "\(NSHomeDirectory())/code/dayflow/Dayflow-macOS",
            "\(NSHomeDirectory())/Developer/dayflow/Dayflow-macOS",
            "\(NSHomeDirectory())/Projects/dayflow/Dayflow-macOS",
        ]
    }

    /// Resolved checkout path, or nil when no candidate has an
    /// executable `build.sh`. Computed lazily on every access so a
    /// developer who clones the repo into a fresh location after the
    /// app is open can still pick it up by re-opening the menu.
    static var repoPath: String? {
        let fm = FileManager.default
        for p in repoCandidates {
            if fm.isExecutableFile(atPath: "\(p)/build.sh") { return p }
        }
        return nil
    }

    /// Hand the rebuild to a detached shell helper, then quit ourselves.
    /// The helper waits for our PID to disappear, runs `build.sh` (which
    /// reinstalls into `/Applications/Dayflow.app`), and `open`s the new
    /// bundle. Detachment via `Process` + a fresh session means the
    /// helper outlives our termination.
    static func rebuildAndRelaunch() {
        guard let repo = repoPath else {
            NSSound.beep()
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = "/Applications/Dayflow.app"
        let logPath = "/tmp/dayflow-rebuild.log"

        // The helper is a single bash command line. We escape `repo`
        // and `appPath` via single-quote wrapping so a path with
        // spaces stays intact.
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        cd '\(repo)' || exit 1
        ./build.sh > '\(logPath)' 2>&1 || { echo 'rebuild FAILED — see \(logPath)'; osascript -e 'display notification "build.sh failed — see /tmp/dayflow-rebuild.log" with title "Dayflow Rebuild"'; exit 1; }
        open '\(appPath)'
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        // Discard helper stdio so we don't keep file handles alive
        // past our own termination.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("dayflow: rebuild helper spawn failed: \(error)")
            NSSound.beep()
            return
        }

        // Defer terminate so the helper has a tick to enter its wait
        // loop before our PID disappears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }
}
