import Foundation
import Observation

// MARK: - preferences

enum GoogleCalendarPreference {
    static let enabledKey = "dayflow.gcal.enabled"
    static let calendarsKey = "dayflow.gcal.calendars"
    static let lastSyncKey = "dayflow.gcal.lastSyncAt"

    /// How far the mirror reaches. Past days exist so the Week/Month views
    /// aren't full of holes when you look back; the future bound is what
    /// bounds the request size.
    static let pastDays = 30
    static let futureDays = 180

    /// Automatic re-sync interval. Google Calendar is not a chat app —
    /// half-hourly is well inside anyone's tolerance and stays far away from
    /// the API quota.
    static let refreshInterval: TimeInterval = 30 * 60

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Calendar ids to mirror. Empty means "primary only" — a fresh connect
    /// shouldn't dump every shared and subscribed calendar into the app.
    static var selectedCalendars: [String] {
        get { UserDefaults.standard.stringArray(forKey: calendarsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: calendarsKey) }
    }

    static var lastSyncAt: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncKey) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: calendarsKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }
}

// MARK: - API types

struct GoogleCalendarInfo: Identifiable, Equatable, Sendable {
    let id: String
    let summary: String
    let primary: Bool
}

/// Read-only slice of the Google Calendar v3 API.
struct GoogleCalendarAPI: Sendable {
    static let shared = GoogleCalendarAPI()

    private static let base = "https://www.googleapis.com/calendar/v3"

    func calendars() async throws -> [GoogleCalendarInfo] {
        var comps = URLComponents(string: "\(Self.base)/users/me/calendarList")!
        comps.queryItems = [.init(name: "minAccessRole", value: "reader")]
        let payload: CalendarListResponse = try await get(comps.url!)
        return payload.items.map {
            GoogleCalendarInfo(id: $0.id,
                               summary: $0.summary ?? $0.id,
                               primary: $0.primary ?? false)
        }
    }

    /// Every event in `[from, to]` on one calendar, following pagination.
    ///
    /// `singleEvents=true` is what makes recurrence tractable: Google expands
    /// each series into its individual instances, so a weekly standup arrives
    /// as N dated events instead of an RRULE we'd have to evaluate ourselves.
    func events(calendarID: String, from: Date, to: Date) async throws -> [MirroredAppointment] {
        var out: [MirroredAppointment] = []
        var pageToken: String?
        // A hard page cap. Without it a pathological calendar (or a bug on
        // either side handing back the same nextPageToken) would spin forever.
        var pagesLeft = 20

        repeat {
            let escaped = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
            var comps = URLComponents(string: "\(Self.base)/calendars/\(escaped)/events")!
            var items: [URLQueryItem] = [
                .init(name: "timeMin", value: DF.rfc3339.string(from: from)),
                .init(name: "timeMax", value: DF.rfc3339.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "showDeleted", value: "false"),
                .init(name: "maxResults", value: "250"),
            ]
            if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
            comps.queryItems = items

            let payload: EventListResponse = try await get(comps.url!)
            out.append(contentsOf: payload.items.compactMap {
                Self.map($0, calendarID: calendarID)
            })
            pageToken = payload.nextPageToken
            pagesLeft -= 1
        } while pageToken != nil && pagesLeft > 0

        return out
    }

    // MARK: mapping

    /// Google → Dayflow. Returns nil for anything Dayflow has no room for.
    static func map(_ event: RawEvent, calendarID: String) -> MirroredAppointment? {
        guard event.status != "cancelled" else { return nil }
        guard let start = event.start else { return nil }

        let title = (event.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let externalID = "\(calendarID)|\(event.id)"

        if let startStamp = start.dateTime {
            guard let startAt = DF.parseRFC3339(startStamp) else { return nil }
            let endAt = event.end?.dateTime.flatMap { DF.parseRFC3339($0) }
            return MirroredAppointment(
                externalID: externalID,
                startAt: startAt,
                // A zero-length or backwards range carries no information;
                // drop it so the row renders as a point in time.
                endAt: (endAt.map { $0 > startAt } ?? false) ? endAt : nil,
                title: title.isEmpty ? L("gcal.untitled") : title,
                note: event.location?.isEmpty == false ? event.location : nil,
                isAllDay: false
            )
        }

        // All-day form: `start.date` / `end.date`, and Google's end date is
        // EXCLUSIVE — a single-day event on the 3rd arrives as 3rd → 4th. Step
        // back a day so a one-day event doesn't render as a two-day span.
        guard let startDay = start.date, let startAt = DF.ymd.date(from: startDay) else { return nil }
        let cal = Calendar.current
        var endAt: Date?
        if let endDay = event.end?.date,
           let exclusive = DF.ymd.date(from: endDay),
           let lastDay = cal.date(byAdding: .day, value: -1, to: exclusive),
           lastDay > startAt {
            endAt = cal.date(bySettingHour: 23, minute: 59, second: 0, of: lastDay)
        }
        return MirroredAppointment(
            externalID: externalID,
            startAt: cal.startOfDay(for: startAt),
            endAt: endAt,
            title: title.isEmpty ? L("gcal.untitled") : title,
            note: event.location?.isEmpty == false ? event.location : nil,
            isAllDay: true
        )
    }

    // MARK: transport

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let token = try await GoogleOAuth.shared.validAccessToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.tokenExchangeFailed("no response")
        }
        if http.statusCode == 401 {
            // The refresh token was revoked from the Google side (password
            // change, "remove access" in the account page). Force a re-auth
            // rather than retrying into a wall.
            await GoogleOAuth.shared.invalidate()
            throw GoogleAuthError.notConnected
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.denied("HTTP \(http.statusCode) — \(body.prefix(200))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: wire types

    private struct CalendarListResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let summary: String?
            let primary: Bool?
        }
        let items: [Item]
    }

    struct RawEvent: Decodable {
        struct Stamp: Decodable {
            let date: String?
            let dateTime: String?
        }
        let id: String
        let status: String?
        let summary: String?
        let location: String?
        let start: Stamp?
        let end: Stamp?
    }

    private struct EventListResponse: Decodable {
        let items: [RawEvent]
        let nextPageToken: String?
    }
}

// MARK: - sync coordinator

/// Owns the mirror: when to pull, what to write, what the UI shows about it.
@MainActor
@Observable
final class GoogleCalendarSync {
    static let shared = GoogleCalendarSync()

    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncAt: Date? = GoogleCalendarPreference.lastSyncAt
    private(set) var calendars: [GoogleCalendarInfo] = []

    @ObservationIgnored private weak var store: DayflowStore?
    @ObservationIgnored private var timer: Timer?

    func bootstrap(store: DayflowStore) {
        self.store = store
        guard GoogleCalendarPreference.enabled, GoogleCredentials.isConnected else { return }
        Task { await syncNow() }
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: GoogleCalendarPreference.refreshInterval,
                                     repeats: true) { _ in
            Task { @MainActor in await GoogleCalendarSync.shared.syncNow() }
        }
        // The app spends most of its life with a menu tracking the run loop;
        // a default-mode timer would just not fire.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Interactive connect. Opens the browser, waits for consent, then does a
    /// first sync so the user sees their events immediately.
    func connect() async {
        guard GoogleCredentials.hasClient else {
            lastError = GoogleAuthError.missingCredentials.localizedDescription
            return
        }
        lastError = nil
        do {
            try await GoogleOAuth.shared.connect(
                clientID: GoogleCredentials.clientID,
                clientSecret: GoogleCredentials.clientSecret ?? ""
            )
            GoogleCalendarPreference.enabled = true
            await refreshCalendarList()
            await syncNow()
            startTimer()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forget the grant and remove every mirrored row. Local appointments the
    /// user typed are untouched.
    func disconnect() {
        stopTimer()
        GoogleCredentials.forgetGrant()
        GoogleCalendarPreference.reset()
        Task { await GoogleOAuth.shared.invalidate() }
        store?.db.deleteMirroredAppointments(source: .google)
        store?.reloadAppointments()
        calendars = []
        lastSyncAt = nil
        lastError = nil
    }

    func refreshCalendarList() async {
        guard GoogleCredentials.isConnected else { return }
        do {
            calendars = try await GoogleCalendarAPI.shared.calendars()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func syncNow() async -> Int {
        guard !isSyncing else { return 0 }
        guard GoogleCredentials.isConnected, let store else { return 0 }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let from = cal.date(byAdding: .day, value: -GoogleCalendarPreference.pastDays, to: today),
              let to = cal.date(byAdding: .day, value: GoogleCalendarPreference.futureDays, to: today) else {
            return 0
        }

        var ids = GoogleCalendarPreference.selectedCalendars
        if ids.isEmpty { ids = ["primary"] }

        var collected: [MirroredAppointment] = []
        do {
            for id in ids {
                collected += try await GoogleCalendarAPI.shared.events(calendarID: id, from: from, to: to)
            }
        } catch {
            lastError = error.localizedDescription
            return 0
        }

        store.db.replaceMirroredAppointments(collected, source: .google, windowStart: from, windowEnd: to)
        store.reloadAppointments()

        let now = Date()
        GoogleCalendarPreference.lastSyncAt = now
        lastSyncAt = now
        return collected.count
    }
}
