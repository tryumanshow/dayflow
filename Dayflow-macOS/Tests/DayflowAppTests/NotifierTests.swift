import Testing
import Foundation
@testable import DayflowApp

// The scheduling itself goes through `UNUserNotificationCenter`, which needs a
// real signed app bundle — it can't run in the test process. What's testable
// (and what would actually be wrong) is the query that decides *which*
// appointments get a reminder at all.

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-notify-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func hoursFromNow(_ h: Double) -> Date {
    Date().addingTimeInterval(h * 3600)
}

@Test func upcomingSkipsPastAppointments() {
    let db = tempDB()
    _ = db.insertAppointment(startAt: hoursFromNow(-2), endAt: nil, title: "already happened",
                             note: nil, category: .event)
    _ = db.insertAppointment(startAt: hoursFromNow(2), endAt: nil, title: "still ahead",
                             note: nil, category: .event)

    let upcoming = db.upcomingAppointments(after: Date(), limit: 60)
    #expect(upcoming.map(\.title) == ["still ahead"])
}

@Test func upcomingIsSoonestFirst() {
    let db = tempDB()
    _ = db.insertAppointment(startAt: hoursFromNow(72), endAt: nil, title: "third", note: nil, category: .event)
    _ = db.insertAppointment(startAt: hoursFromNow(1), endAt: nil, title: "first", note: nil, category: .event)
    _ = db.insertAppointment(startAt: hoursFromNow(24), endAt: nil, title: "second", note: nil, category: .event)

    let upcoming = db.upcomingAppointments(after: Date(), limit: 60)
    #expect(upcoming.map(\.title) == ["first", "second", "third"])
}

/// macOS drops pending local notifications past 64. The limit exists so the
/// ones we lose are the furthest out, not an arbitrary slice.
@Test func upcomingHonoursTheScheduleBudget() {
    let db = tempDB()
    for i in 1...80 {
        _ = db.insertAppointment(startAt: hoursFromNow(Double(i)), endAt: nil,
                                 title: "apt \(i)", note: nil, category: .event)
    }
    let upcoming = db.upcomingAppointments(after: Date(), limit: AppointmentNotifier.maxScheduled)
    #expect(upcoming.count == AppointmentNotifier.maxScheduled)
    #expect(upcoming.count < 64)
    // Kept the soonest, dropped the furthest.
    #expect(upcoming.first?.title == "apt 1")
    #expect(upcoming.last?.title == "apt \(AppointmentNotifier.maxScheduled)")
}

@Test func upcomingCarriesTheFieldsTheReminderNeeds() {
    let db = tempDB()
    let start = hoursFromNow(5)
    _ = db.insertAppointment(startAt: start, endAt: nil, title: "치과 예약",
                             note: nil, category: .reminder)

    let apt = db.upcomingAppointments(after: Date(), limit: 60).first
    #expect(apt?.title == "치과 예약")
    #expect(apt?.category == .reminder)
    // Minute precision — the storage format has no seconds slot.
    #expect(DF.appointmentStamp.string(from: apt!.startAt)
            == DF.appointmentStamp.string(from: start))
}

// MARK: - preferences

/// Reminders must be off until the user asks, so we never fire the macOS
/// permission prompt at someone who didn't opt in.
@Test func notificationsAreOffByDefault() {
    let defaults = UserDefaults.standard
    #expect(defaults.object(forKey: NotificationPreference.enabledKey) == nil
            || defaults.bool(forKey: NotificationPreference.enabledKey) == NotificationPreference.enabled)
    // An unset key reads as disabled.
    #expect(defaults.bool(forKey: "dayflow.notifications.enabled.unset-probe") == false)
}

/// `UserDefaults.integer(forKey:)` returns 0 for a key that was never
/// written — indistinguishable from a deliberate "at start time" (0 min).
/// The accessor has to tell those apart or every fresh install silently
/// gets zero lead instead of the 10-minute default.
@Test func leadMinutesDefaultsWhenUnset() {
    #expect(NotificationPreference.leadMinutesDefault == 10)
    #expect(NotificationPreference.leadChoices.contains(0))
    #expect(NotificationPreference.leadChoices.contains(NotificationPreference.leadMinutesDefault))

    let suite = UserDefaults(suiteName: "dayflow-test-\(UUID().uuidString)")!
    // Never written → 0, which is why the raw accessor can't be trusted alone.
    #expect(suite.integer(forKey: NotificationPreference.leadMinutesKey) == 0)
    #expect(suite.object(forKey: NotificationPreference.leadMinutesKey) == nil)
}
