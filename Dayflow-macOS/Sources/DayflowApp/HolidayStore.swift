import Foundation

/// Which country's holidays the user wants surfaced in the
/// calendar views. Persisted under `AppStorageKeys.holidaysMode`.
enum HolidayDisplayMode: String, CaseIterable, Identifiable {
    case off
    case kr
    case us
    case both

    var id: String { rawValue }

    var countryCodes: [String] {
        switch self {
        case .off:  return []
        case .kr:   return ["KR"]
        case .us:   return ["US"]
        case .both: return ["KR", "US"]
        }
    }

    var label: String {
        switch self {
        case .off:  return L("settings.holidays.off")
        case .kr:   return L("settings.holidays.kr")
        case .us:   return L("settings.holidays.us")
        case .both: return L("settings.holidays.both")
        }
    }
}

/// Bundled public holiday lookup for KR + US. Data lives in
/// `Resources/holidays.json` and covers 2026-2030; update the JSON
/// annually for fresh years. No network, no permissions — matches
/// Dayflow's local-first ethos.
enum HolidayStore {
    struct Holiday {
        let date: Date
        let name: String
        let country: String
    }

    /// Pre-indexed lookup: `"yyyy-MM-dd"` → holidays falling on that
    /// day. Multiple entries are possible when the user selects
    /// `both` (e.g. New Year's Day in both KR and US).
    private static let lookup: [String: [Holiday]] = {
        guard let url = Bundle.module.url(forResource: "holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: [RawHoliday]].self, from: data) else {
            NSLog("dayflow: holidays.json missing or malformed")
            return [:]
        }
        var out: [String: [Holiday]] = [:]
        for (country, rows) in parsed {
            for row in rows {
                guard let date = DF.ymd.date(from: row.date) else { continue }
                let h = Holiday(date: date, name: row.name, country: country)
                out[row.date, default: []].append(h)
            }
            for sub in computeKRSubstitutes(country: country, rows: rows) {
                let key = DayflowDB.ymd(sub.date)
                out[key, default: []].append(sub)
            }
        }
        return out
    }()

    /// Korean 대체공휴일법 (Substitute Holiday Act) computation.
    /// Generates a substitute Monday-ish entry when a covered holiday
    /// lands on a weekend, mirroring the gov't rule so we don't have
    /// to hand-maintain every year's edge cases in JSON.
    ///
    /// Rules (as of 2023+):
    /// - 3·1절 / 광복절 / 개천절 / 한글날 / 어린이날 / 부처님오신날 / 성탄절
    ///   → if Saturday or Sunday, substitute on next non-holiday weekday.
    /// - 설날 / 추석 (each 3 days) → if Sunday OR overlaps another
    ///   public holiday, substitute on next non-holiday weekday.
    /// - 새해, 현충일 → no substitute.
    /// Skips generation when the source JSON already encodes the
    /// substitute (same name appearing on a date within the following
    /// 3 days), so manual entries don't get duplicated.
    private static func computeKRSubstitutes(country: String, rows: [RawHoliday]) -> [Holiday] {
        guard country == "KR" else { return [] }
        let cal = Calendar(identifier: .gregorian)

        var datesByKey: [String: [String]] = [:]
        var dateOf: [String: Date] = [:]
        for r in rows {
            guard let d = DF.ymd.date(from: r.date) else { continue }
            datesByKey[r.date, default: []].append(r.name)
            dateOf[r.date] = d
        }

        let weekendRule: Set<String> = ["어린이날", "부처님 오신 날", "크리스마스", "3·1절", "광복절", "개천절", "한글날"]
        let lunarRule: Set<String> = ["설날", "추석"]

        func alreadyBaked(name: String, after origin: Date) -> Bool {
            for offset in 1...3 {
                guard let next = cal.date(byAdding: .day, value: offset, to: origin) else { continue }
                let key = DayflowDB.ymd(next)
                let names = datesByKey[key] ?? []
                if names.contains(name) || names.contains("\(name) 대체") { return true }
            }
            return false
        }

        var occupied = Set(datesByKey.keys)
        func nextFreeWeekday(after origin: Date) -> Date? {
            var cur = origin
            for _ in 0..<14 {
                guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { return nil }
                cur = next
                let wd = cal.component(.weekday, from: cur)
                let key = DayflowDB.ymd(cur)
                if wd != 1 && wd != 7 && !occupied.contains(key) { return cur }
            }
            return nil
        }

        var substitutes: [Holiday] = []
        for key in datesByKey.keys.sorted() {
            let names = datesByKey[key]!
            let d = dateOf[key]!
            let wd = cal.component(.weekday, from: d)
            for name in names {
                let needs: Bool
                if weekendRule.contains(name) {
                    needs = (wd == 1 || wd == 7)
                } else if lunarRule.contains(name) {
                    let overlap = names.contains(where: { $0 != name })
                    needs = (wd == 1) || overlap
                } else {
                    needs = false
                }
                if !needs { continue }
                if alreadyBaked(name: name, after: d) { continue }
                guard let sub = nextFreeWeekday(after: d) else { continue }
                occupied.insert(DayflowDB.ymd(sub))
                substitutes.append(Holiday(date: sub, name: "\(name) 대체", country: country))
            }
        }
        return substitutes
    }

    private struct RawHoliday: Decodable {
        let date: String
        let name: String
    }

    /// Holidays falling on `date` filtered by the active display
    /// mode. Empty array if the day isn't a holiday or mode is `.off`.
    static func holidays(on date: Date, mode: HolidayDisplayMode) -> [Holiday] {
        guard !mode.countryCodes.isEmpty else { return [] }
        let key = DayflowDB.ymd(date)
        return (lookup[key] ?? []).filter { mode.countryCodes.contains($0.country) }
    }

    /// Name of the first holiday on `date` (only the first is shown
    /// anywhere in the UI — cells / headers don't have room for more).
    static func holidayName(on date: Date, mode: HolidayDisplayMode) -> String? {
        holidays(on: date, mode: mode).first?.name
    }
}
