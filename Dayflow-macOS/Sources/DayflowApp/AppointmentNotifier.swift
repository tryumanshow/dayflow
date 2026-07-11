import Foundation
import UserNotifications
import AppKit

/// Local notifications for upcoming appointments.
///
/// Everything is scheduled up front with `UNCalendarNotificationTrigger`, so
/// reminders fire whether or not Dayflow is running — no background timer, no
/// polling. The full set is torn down and rebuilt whenever appointments or the
/// user's settings change, which is far simpler than diffing and costs nothing
/// at this scale.
@MainActor
final class AppointmentNotifier: NSObject {
    static let shared = AppointmentNotifier()

    /// macOS keeps only the first 64 pending local notifications per app and
    /// silently drops the rest. Staying comfortably under that means a user
    /// who schedules far ahead loses the *furthest-out* reminders rather than
    /// having the system pick arbitrarily — and each reschedule (every
    /// appointment edit, every launch) pulls the next ones into range.
    static let maxScheduled = 60

    private static let idPrefix = "dayflow.apt."

    /// Only ever `true` after the user opted in AND macOS granted us the
    /// permission. Every scheduling path checks it, so a denied prompt just
    /// means no notifications rather than a pile of silent failures.
    private var authorized = false

    private override init() {
        super.init()
    }

    /// Must run before any appointment is scheduled — installs the delegate
    /// that lets a reminder show while Dayflow is the frontmost app (macOS
    /// suppresses banners for the active app otherwise) and handles taps.
    func bootstrap(store: DayflowStore) {
        self.store = store
        UNUserNotificationCenter.current().delegate = self
        Task { await syncAuthorization() }
    }

    private weak var store: DayflowStore?

    // MARK: - permission

    /// Reconciles our cached flag with what macOS actually thinks, then
    /// reschedules. Called on launch: the user can revoke the permission in
    /// System Settings while the app is closed, and turning the toggle back on
    /// in Dayflow shouldn't be what discovers that.
    func syncAuthorization() async {
        guard NotificationPreference.enabled else {
            authorized = false
            await clearAll()
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        Self.diag("syncAuthorization: status=\(settings.authorizationStatus.rawValue)")
        // Reminders are on but macOS has no decision on record — the app was
        // reinstalled, or the prompt never completed. Ask now rather than
        // leaving the toggle claiming a capability we never obtained.
        if settings.authorizationStatus == .notDetermined {
            await requestAuthorization()
            return
        }
        authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        await rescheduleAll()
    }

    /// Ask macOS for permission. Returns whether we ended up authorized —
    /// the Settings toggle uses this to flip itself back off if the user
    /// declined, so the UI never claims a capability we don't have.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            authorized = granted
            Self.diag("requestAuthorization -> granted=\(granted)")
        } catch {
            NSLog("dayflow: notification authorization failed: \(error.localizedDescription)")
            Self.diag("requestAuthorization THREW: \(error)")
            authorized = false
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        Self.diag("status=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue)")
        await rescheduleAll()
        return authorized
    }

    /// Diagnostics sink. This feature fails *silently* when macOS declines —
    /// no crash, no banner, just nothing — and `NSLog` from a GUI app goes
    /// nowhere reachable. Point `DAYFLOW_DIAG_LOG` at a file to find out why.
    static func diag(_ msg: String) {
        guard let path = ProcessInfo.processInfo.environment["DAYFLOW_DIAG_LOG"] else { return }
        let line = "\(Date()) \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - scheduling

    /// Tear down every pending Dayflow reminder and rebuild from the DB.
    func rescheduleAll() async {
        await clearAll()
        guard authorized, NotificationPreference.enabled, let store else {
            Self.diag("rescheduleAll skipped (authorized=\(authorized) enabled=\(NotificationPreference.enabled))")
            return
        }

        let lead = TimeInterval(NotificationPreference.leadMinutes * 60)
        let now = Date()
        let center = UNUserNotificationCenter.current()
        var scheduled = 0

        for apt in store.db.upcomingAppointments(after: now, limit: Self.maxScheduled) {
            let fireAt = apt.startAt.addingTimeInterval(-lead)
            // An appointment whose lead window has already elapsed (booked for
            // 10 minutes from now with a 30-minute lead) gets no reminder —
            // firing immediately would be noise, not a heads-up.
            guard fireAt > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = apt.title
            content.body = Self.subtitle(for: apt, leadMinutes: NotificationPreference.leadMinutes)
            content.sound = .default
            content.userInfo = ["ymd": DayflowDB.ymd(apt.startAt)]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(Self.idPrefix)\(apt.id)",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                NSLog("dayflow: failed to schedule reminder for appointment \(apt.id): \(error.localizedDescription)")
                Self.diag("schedule FAILED for \(apt.id): \(error)")
            }
        }
        Self.diag("scheduled \(scheduled) reminder(s), lead=\(NotificationPreference.leadMinutes)m")
    }

    private func clearAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    /// "14:00 · starts in 10 min" — the time it starts, and how much runway is
    /// left. A zero lead means the banner lands as it begins, so "in 0 min"
    /// would be a silly way to say "now".
    private static func subtitle(for apt: Appointment, leadMinutes: Int) -> String {
        let time = DF.hourMinute.string(from: apt.startAt)
        let tail = leadMinutes == 0
            ? L("notify.starting_now")
            : L("notify.lead_body", leadMinutes)
        return "\(time) · \(tail)"
    }
}

// MARK: - delegate

extension AppointmentNotifier: UNUserNotificationCenterDelegate {
    /// Without this, macOS drops the banner whenever Dayflow happens to be
    /// the frontmost app — which is exactly when a user sitting in their
    /// planner most wants the nudge.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking the banner opens the day the appointment sits on.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let ymd = info["ymd"] as? String,
              let date = DF.ymd.date(from: ymd) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            store?.selectDate(date)
            store?.setMode(.day)
        }
    }
}

// MARK: - preferences

/// Notifications are opt-in. Defaulting them on would fire the macOS
/// permission prompt at first launch, before the user has any reason to want
/// reminders — the surest way to get denied permanently.
enum NotificationPreference {
    static let enabledKey = "dayflow.notifications.enabled"
    static let leadMinutesKey = "dayflow.notifications.leadMinutes"
    static let leadMinutesDefault = 10

    /// The choices worth offering: right as it starts, or one of the usual
    /// "time to wrap up and walk over" windows.
    static let leadChoices = [0, 5, 10, 30, 60]

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var leadMinutes: Int {
        let raw = UserDefaults.standard.integer(forKey: leadMinutesKey)
        return raw == 0 && UserDefaults.standard.object(forKey: leadMinutesKey) == nil
            ? leadMinutesDefault
            : raw
    }
}
