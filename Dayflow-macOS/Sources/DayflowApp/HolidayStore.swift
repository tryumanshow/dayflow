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
        }
        return out
    }()

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
