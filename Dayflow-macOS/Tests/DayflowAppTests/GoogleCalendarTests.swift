import Testing
import Foundation
@testable import DayflowApp

// The OAuth round-trip and the HTTP calls need a real Google account, so they
// can't run here. What *can* be wrong without anyone noticing is the pure
// stuff: how Google's event shapes map onto Dayflow's, how the redirect is
// parsed, and whether a re-sync is actually idempotent.

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-gcal-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func stamp(_ s: String) -> GoogleCalendarAPI.RawEvent.Stamp {
    s.contains("T") ? .init(date: nil, dateTime: s) : .init(date: s, dateTime: nil)
}

private func event(
    id: String = "evt1",
    status: String? = "confirmed",
    summary: String? = "Standup",
    location: String? = nil,
    start: String?,
    end: String? = nil
) -> GoogleCalendarAPI.RawEvent {
    .init(id: id, status: status, summary: summary, location: location,
          start: start.map(stamp), end: end.map(stamp))
}

// MARK: - event mapping

@Test func mapsATimedEvent() {
    let e = event(start: "2026-07-13T09:30:00+09:00", end: "2026-07-13T10:00:00+09:00")
    let m = GoogleCalendarAPI.map(e, calendarID: "primary")

    #expect(m?.title == "Standup")
    #expect(m?.isAllDay == false)
    #expect(m?.externalID == "primary|evt1")
    // Stored as local wall-clock, which is what the whole app runs on.
    #expect(DF.hourMinute.string(from: m!.startAt)
            == DF.hourMinute.string(from: DF.parseRFC3339("2026-07-13T09:30:00+09:00")!))
    #expect(m?.endAt != nil)
}

/// Google's all-day `end.date` is EXCLUSIVE: a one-day event on the 13th
/// arrives as 13th → 14th. Taken literally it would render as a two-day span
/// bleeding into the next day — which is exactly the bug this guards.
@Test func allDayEndDateIsExclusiveAndGetsSteppedBack() {
    let e = event(summary: "Public holiday", start: "2026-07-13", end: "2026-07-14")
    let m = GoogleCalendarAPI.map(e, calendarID: "primary")

    #expect(m?.isAllDay == true)
    #expect(DayflowDB.ymd(m!.startAt) == "2026-07-13")
    // A single-day event has no meaningful end — it must not spill into the 14th.
    #expect(m?.endAt == nil)
}

@Test func multiDayAllDayEventKeepsItsLastRealDay() {
    // Google: 16th → 18th exclusive == the 16th and the 17th.
    let e = event(summary: "Busan trip", start: "2026-07-16", end: "2026-07-18")
    let m = GoogleCalendarAPI.map(e, calendarID: "primary")

    #expect(DayflowDB.ymd(m!.startAt) == "2026-07-16")
    #expect(DayflowDB.ymd(m!.endAt!) == "2026-07-17")
}

@Test func allDayEventStartsAtMidnight() {
    let m = GoogleCalendarAPI.map(event(start: "2026-07-13"), calendarID: "primary")
    let comps = Calendar.current.dateComponents([.hour, .minute], from: m!.startAt)
    #expect(comps.hour == 0)
    #expect(comps.minute == 0)
}

@Test func cancelledEventsAreDropped() {
    let e = event(status: "cancelled", start: "2026-07-13T09:30:00+09:00")
    #expect(GoogleCalendarAPI.map(e, calendarID: "primary") == nil)
}

@Test func eventWithNoStartIsDropped() {
    #expect(GoogleCalendarAPI.map(event(start: nil), calendarID: "primary") == nil)
}

/// A meeting with no title is a real thing people have on their calendars.
/// It has to come through with *some* label, not an empty chip.
@Test func untitledEventGetsAPlaceholder() {
    let e = event(summary: nil, start: "2026-07-13T09:30:00+09:00")
    let m = GoogleCalendarAPI.map(e, calendarID: "primary")
    #expect(m != nil)
    #expect(m?.title.isEmpty == false)
}

/// A zero-length range says nothing; the row should render as a point in time
/// rather than a 0-minute span.
@Test func zeroLengthRangeDropsTheEnd() {
    let e = event(start: "2026-07-13T09:30:00+09:00", end: "2026-07-13T09:30:00+09:00")
    #expect(GoogleCalendarAPI.map(e, calendarID: "primary")?.endAt == nil)
}

/// The external id is scoped by calendar — the same event id can legitimately
/// appear on two calendars the user has both selected.
@Test func externalIDIsScopedByCalendar() {
    let a = GoogleCalendarAPI.map(event(start: "2026-07-13T09:30:00+09:00"), calendarID: "work@x.com")
    let b = GoogleCalendarAPI.map(event(start: "2026-07-13T09:30:00+09:00"), calendarID: "primary")
    #expect(a?.externalID != b?.externalID)
}

// MARK: - loopback redirect parsing

@Test func parsesTheAuthorizationCodeOffTheRedirect() throws {
    let raw = "GET /?code=4%2F0AbCd_efg&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    let code = try LoopbackAuthReceiver.parse(requestLine: raw).get()
    #expect(code == "4/0AbCd_efg")
}

@Test func aDeniedConsentIsReportedAsCancellation() {
    let raw = "GET /?error=access_denied HTTP/1.1\r\n\r\n"
    let result = LoopbackAuthReceiver.parse(requestLine: raw)
    guard case .failure(let err) = result else {
        Issue.record("expected a failure")
        return
    }
    #expect(err is GoogleAuthError)
    if case GoogleAuthError.userCancelled = err {} else {
        Issue.record("expected userCancelled, got \(err)")
    }
}

@Test func aRedirectWithNoCodeIsAFailure() {
    let result = LoopbackAuthReceiver.parse(requestLine: "GET / HTTP/1.1\r\n\r\n")
    guard case .failure = result else {
        Issue.record("a redirect with no code must not resolve to a code")
        return
    }
}

/// The whole "no nginx needed" claim rests on this: the app can open a real
/// socket on loopback, a browser can hit it, and the code comes back. Google's
/// half can't be exercised here, but ours can — this drives the actual
/// `NWListener` and speaks HTTP to it.
@Test func theLoopbackReceiverAcceptsARealRedirect() async throws {
    let receiver = LoopbackAuthReceiver()
    let port = try receiver.start()
    #expect(port > 0)

    Task.detached {
        // Whatever the browser would have sent after consent.
        let url = URL(string: "http://127.0.0.1:\(port)/?code=test-code-123&scope=calendar.readonly")!
        _ = try? await URLSession.shared.data(from: url)
    }

    let code = try await receiver.waitForCode(timeout: 10)
    #expect(code == "test-code-123")
}

/// And the deny path, which is the one that silently hangs if it's wrong.
@Test func theLoopbackReceiverSurfacesADeniedConsent() async {
    let receiver = LoopbackAuthReceiver()
    guard let port = try? receiver.start() else {
        Issue.record("listener failed to bind")
        return
    }

    Task.detached {
        let url = URL(string: "http://127.0.0.1:\(port)/?error=access_denied")!
        _ = try? await URLSession.shared.data(from: url)
    }

    do {
        _ = try await receiver.waitForCode(timeout: 10)
        Issue.record("a denied consent must not resolve to a code")
    } catch let err as GoogleAuthError {
        if case .userCancelled = err {} else {
            Issue.record("expected userCancelled, got \(err)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - PKCE

@Test func pkceVerifierIsUrlSafeAndLongEnough() {
    let v = PKCE.makeVerifier()
    // RFC 7636 requires 43–128 characters from the unreserved set.
    #expect(v.count >= 43 && v.count <= 128)
    #expect(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
}

@Test func pkceVerifierIsNotConstant() {
    #expect(PKCE.makeVerifier() != PKCE.makeVerifier())
}

/// The S256 challenge for a known verifier, from RFC 7636 Appendix B.
@Test func pkceChallengeMatchesTheRFCVector() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

/// A `+` in a client secret would decode server-side as a space if it went out
/// unescaped, and the token exchange would fail with a useless error.
@Test func formEncodingEscapesPlusAndSlash() {
    let encoded = GoogleOAuth.formEncode(["secret": "a+b/c=d"])
    #expect(!encoded.contains("+"))
    #expect(encoded == "secret=a%2Bb%2Fc%3Dd")
}

// MARK: - mirroring into the DB

private func mirrored(_ id: String, _ hhmm: String, title: String = "meeting", allDay: Bool = false) -> MirroredAppointment {
    let start = DF.appointmentStamp.date(from: "2026-07-13T\(hhmm)")!
    return MirroredAppointment(externalID: id, startAt: start, endAt: nil,
                               title: title, note: nil, isAllDay: allDay)
}

private let windowStart = DF.appointmentStamp.date(from: "2026-07-01T00:00")!
private let windowEnd = DF.appointmentStamp.date(from: "2026-07-31T23:59")!

@Test func mirroringImportsEventsAsReadOnlyRows() {
    let db = tempDB()
    db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)

    let rows = db.getAppointments(start: windowStart, end: windowEnd)
    #expect(rows.count == 1)
    #expect(rows.first?.source == .google)
    #expect(rows.first?.isReadOnly == true)
}

/// Re-running the same sync must not pile up duplicates — the unique index on
/// `external_id` plus the upsert is what makes that true.
@Test func resyncingTheSameEventsIsIdempotent() {
    let db = tempDB()
    let events = [mirrored("a", "09:30"), mirrored("b", "11:00")]
    for _ in 0..<3 {
        db.replaceMirroredAppointments(events, source: .google,
                                       windowStart: windowStart, windowEnd: windowEnd)
    }
    #expect(db.getAppointments(start: windowStart, end: windowEnd).count == 2)
}

/// The row id survives a re-sync. Notification identifiers and the Month rail's
/// selection are keyed on it — churning ids every 30 minutes would make both
/// flicker for no reason.
@Test func resyncKeepsTheRowID() {
    let db = tempDB()
    db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)
    let first = db.getAppointments(start: windowStart, end: windowEnd).first?.id

    db.replaceMirroredAppointments([mirrored("a", "09:30", title: "renamed")], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)
    let after = db.getAppointments(start: windowStart, end: windowEnd).first

    #expect(first != nil)
    #expect(after?.id == first)
    #expect(after?.title == "renamed")
}

@Test func anEventDeletedInGoogleDisappearsOnTheNextSync() {
    let db = tempDB()
    db.replaceMirroredAppointments([mirrored("a", "09:30"), mirrored("b", "11:00")],
                                   source: .google, windowStart: windowStart, windowEnd: windowEnd)
    db.replaceMirroredAppointments([mirrored("a", "09:30")],
                                   source: .google, windowStart: windowStart, windowEnd: windowEnd)

    let rows = db.getAppointments(start: windowStart, end: windowEnd)
    #expect(rows.count == 1)
    #expect(rows.first?.isReadOnly == true)
}

/// The sync only fetches a window, so the prune must only touch that window.
/// A blanket "delete every google row" would silently drop mirrored events
/// sitting outside it and never bring them back.
@Test func mirroredRowsOutsideTheSyncWindowSurvive() {
    let db = tempDB()
    let far = MirroredAppointment(
        externalID: "far",
        startAt: DF.appointmentStamp.date(from: "2027-01-05T09:00")!,
        endAt: nil, title: "next year", note: nil, isAllDay: false)
    db.replaceMirroredAppointments([mirrored("a", "09:30"), far], source: .google,
                                   windowStart: windowStart,
                                   windowEnd: DF.appointmentStamp.date(from: "2027-12-31T23:59")!)

    // Now sync only July. The January row is out of scope and must be left alone.
    db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)

    #expect(db.mirroredAppointmentCount(source: .google) == 2)
}

/// Syncing must never touch an appointment the user typed themselves.
@Test func localAppointmentsAreNeverTouchedBySync() {
    let db = tempDB()
    let mine = DF.appointmentStamp.date(from: "2026-07-13T14:00")!
    _ = db.insertAppointment(startAt: mine, endAt: nil, title: "my own", note: nil, category: .event)

    db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)
    db.replaceMirroredAppointments([], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)

    let rows = db.getAppointments(start: windowStart, end: windowEnd)
    #expect(rows.map(\.title) == ["my own"])
    #expect(rows.first?.source == .local)
}

@Test func disconnectingRemovesEveryMirroredRowAndKeepsLocalOnes() {
    let db = tempDB()
    _ = db.insertAppointment(startAt: DF.appointmentStamp.date(from: "2026-07-13T14:00")!,
                             endAt: nil, title: "my own", note: nil, category: .event)
    db.replaceMirroredAppointments([mirrored("a", "09:30"), mirrored("b", "11:00")],
                                   source: .google, windowStart: windowStart, windowEnd: windowEnd)

    db.deleteMirroredAppointments(source: .google)

    #expect(db.mirroredAppointmentCount(source: .google) == 0)
    #expect(db.getAppointments(start: windowStart, end: windowEnd).map(\.title) == ["my own"])
}

@Test func allDayFlagSurvivesTheRoundTrip() {
    let db = tempDB()
    db.replaceMirroredAppointments([mirrored("a", "00:00", title: "holiday", allDay: true)],
                                   source: .google, windowStart: windowStart, windowEnd: windowEnd)
    let row = db.getAppointments(start: windowStart, end: windowEnd).first
    #expect(row?.isAllDay == true)
    // 00:00 is a storage artifact, not a time the user set — never show it.
    #expect(row?.timeLabel != "00:00")
}

@Test func aTimedRowStillShowsItsClock() {
    let db = tempDB()
    db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                   windowStart: windowStart, windowEnd: windowEnd)
    #expect(db.getAppointments(start: windowStart, end: windowEnd).first?.timeLabel == "09:30")
}

// MARK: - read-only enforcement

/// The Month rail hides the edit and delete buttons on a mirrored row, but the
/// store refuses them too. A delete that "worked" until the next sync brought
/// the event straight back would be worse than no delete at all.
@MainActor
@Test func theStoreRefusesToDeleteAMirroredAppointment() {
    let store = DayflowStore(db: tempDB())
    store.db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                         windowStart: windowStart, windowEnd: windowEnd)
    store.selectedDate = DF.appointmentStamp.date(from: "2026-07-13T09:30")!
    store.refresh(force: true)

    let apt = store.appointments(for: store.selectedDate).first
    #expect(apt?.isReadOnly == true)

    store.deleteAppointment(apt!)

    #expect(store.db.mirroredAppointmentCount(source: .google) == 1)
}

@MainActor
@Test func theStoreRefusesToEditAMirroredAppointment() {
    let store = DayflowStore(db: tempDB())
    store.db.replaceMirroredAppointments([mirrored("a", "09:30")], source: .google,
                                         windowStart: windowStart, windowEnd: windowEnd)
    store.selectedDate = DF.appointmentStamp.date(from: "2026-07-13T09:30")!
    store.refresh(force: true)

    let apt = store.appointments(for: store.selectedDate).first!
    let ok = store.updateAppointment(apt.id, on: store.selectedDate, hhmm: "18:00",
                                     title: "hijacked", category: .event)

    #expect(ok == false)
    store.refresh(force: true)
    let after = store.appointments(for: store.selectedDate).first!
    #expect(after.title == "meeting")
    #expect(after.timeLabel == "09:30")
}

/// A locally-typed appointment must stay fully editable — the guard has to key
/// on the source, not on appointments in general.
@MainActor
@Test func localAppointmentsRemainEditable() {
    let store = DayflowStore(db: tempDB())
    let day = DF.appointmentStamp.date(from: "2026-07-13T09:30")!
    store.selectedDate = day
    #expect(store.addAppointment(on: day, hhmm: "09:30", title: "mine"))

    let apt = store.appointments(for: day).first!
    #expect(store.updateAppointment(apt.id, on: day, hhmm: "10:00", title: "moved", category: .event))
    #expect(store.appointments(for: day).first?.title == "moved")

    store.deleteAppointment(store.appointments(for: day).first!)
    #expect(store.appointments(for: day).isEmpty)
}
