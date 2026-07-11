import Foundation

@MainActor
extension DayflowStore {
    // MARK: - appointments

    /// Per-cell chip list. Spans are drawn as bars by the overlay,
    /// not as per-day chips.
    func appointments(for date: Date) -> [Appointment] {
        (appointmentsByDay[DayflowDB.ymd(date)] ?? []).filter { !$0.isMultiDay }
    }

    /// All appointments whose `startAt` falls within the calendar
    /// month containing `selectedDate`, sorted by `startAt`.
    func currentMonthAppointments() -> [Appointment] {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: selectedDate)),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
        return appointmentsByDay.values
            .flatMap { $0 }
            .filter { $0.startAt >= monthStart && $0.startAt < nextMonth }
            .sorted { $0.startAt < $1.startAt }
    }

    func currentMonthSpans() -> [Appointment] {
        appointmentsByDay.values.flatMap { $0 }
            .filter(\.isMultiDay)
            .sorted { ($0.startAt, $0.id) < ($1.startAt, $1.id) }
    }

    /// Parse `HH:mm` against the target day and insert. `endHHmm` is
    /// optional — empty string / nil means the appointment has no
    /// explicit end, rendering as a point event. Returns false on
    /// empty title or unparseable time.
    @discardableResult
    func addAppointment(on day: Date, hhmm: String, endHHmm: String? = nil, endDay: Date? = nil, title: String, category: AppointmentCategory = .event) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        guard let (startAt, endAt) = Self.resolveTimes(day: day, hhmm: hhmm, endHHmm: endHHmm, endDay: endDay) else { return false }
        db.insertAppointment(startAt: startAt, endAt: endAt, title: trimmedTitle, note: nil, category: category)
        reloadAppointments()
        return true
    }

    /// Mirrored rows are refused here, not just hidden in the UI. The next
    /// sync would resurrect a deleted Google event anyway, so a delete that
    /// "worked" until the next refresh would be a lie.
    func deleteAppointment(_ apt: Appointment) {
        guard !apt.isReadOnly else { return }
        db.deleteAppointment(id: apt.id)
        reloadAppointments()
    }

    /// In-place edit of an existing appointment. Same parsing rules
    /// as `addAppointment` — empty title or bad start time returns
    /// false with no mutation. Empty `endHHmm` clears `end_at`.
    @discardableResult
    func updateAppointment(_ id: Int64, on day: Date, hhmm: String, endHHmm: String? = nil, endDay: Date? = nil, title: String, category: AppointmentCategory) -> Bool {
        // Same reason as delete: an edit to a mirrored row survives only until
        // the next sync overwrites it.
        guard !isReadOnlyAppointment(id) else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        guard let (startAt, endAt) = Self.resolveTimes(day: day, hhmm: hhmm, endHHmm: endHHmm, endDay: endDay) else { return false }
        db.updateAppointment(id: id, startAt: startAt, endAt: endAt, title: trimmedTitle, note: nil, category: category)
        reloadAppointments()
        return true
    }

    /// Looks the row up in the loaded set rather than the DB — the edit form
    /// only ever addresses appointments that are currently on screen.
    func isReadOnlyAppointment(_ id: Int64) -> Bool {
        appointmentsByDay.values
            .flatMap { $0 }
            .first { $0.id == id }?
            .isReadOnly ?? false
    }

    /// Multi-day span (endDay > start day) collapses to 00:00 → 23:59
    /// and ignores the hhmm fields.
    private static func resolveTimes(day: Date, hhmm: String, endHHmm: String?, endDay: Date?) -> (Date, Date?)? {
        let cal = Calendar.current
        if let endDay, !cal.isDate(endDay, inSameDayAs: day), endDay > day {
            let startAt = cal.startOfDay(for: day)
            let endAt = cal.date(bySettingHour: 23, minute: 59, second: 0, of: endDay)
            return (startAt, endAt)
        }
        let trimmedTime = hhmm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startAt = combine(day: day, hhmm: trimmedTime) else { return nil }
        return (startAt, parseOptionalEnd(day: day, hhmm: endHHmm, startAt: startAt))
    }

    /// A zero-duration or negative range is almost certainly a
    /// typo, not an intent — drop it silently so the user just
    /// sees the appointment as "no end".
    private static func parseOptionalEnd(day: Date, hhmm: String?, startAt: Date) -> Date? {
        guard let raw = hhmm?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let end = combine(day: day, hhmm: raw) else { return nil }
        return end > startAt ? end : nil
    }

    /// Parse an `HH:mm` / `H:m` / `HHmm` string and attach it to
    /// `day`'s calendar date. Returns nil on malformed input.
    private static func combine(day: Date, hhmm: String) -> Date? {
        // Forgiving of "HHmm" (no separator) — normalise into a
        // `HH:mm` shape before splitting.
        var normalized = hhmm
        if normalized.count == 4, !normalized.contains(":") {
            let idx = normalized.index(normalized.startIndex, offsetBy: 2)
            normalized = String(normalized[..<idx]) + ":" + String(normalized[idx...])
        }
        let parts = normalized.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let (hour, minute) = (parts[0], parts[1])
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}
