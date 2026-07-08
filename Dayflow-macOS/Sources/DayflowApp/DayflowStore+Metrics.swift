import Foundation

@MainActor
extension DayflowStore {
    // MARK: - metric helpers

    func dayCounts(_ date: Date) -> (open: Int, done: Int) {
        DayflowDB.parseCheckboxes(dayBody(for: date))
    }

    func dayBody(for date: Date) -> String {
        bodies[DayflowDB.ymd(date)] ?? ""
    }

    /// Week-wide aggregate counts (open + done across 7 days) for the week
    /// containing `selectedDate`.
    func weekTotals() -> (open: Int, done: Int, trackedDays: Int) {
        let cal = Calendar.current
        let start = startOfWeek(selectedDate)
        var open = 0
        var done = 0
        var tracked = 0
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            let counts = dayCounts(day)
            if counts.open + counts.done > 0 { tracked += 1 }
            open += counts.open
            done += counts.done
        }
        return (open, done, tracked)
    }

    // MARK: - review

    func loadReview() {
        reviewBody = db.getReview(date: selectedDate) ?? ""
        reviewError = nil
    }

    func generateReview() {
        let target = selectedDate
        let body = db.getDayNote(date: target)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let empty = L("llm.review.empty_day")
            reviewBody = empty
            db.saveReview(date: target, body: empty)
            return
        }

        reviewIsLoading = true
        reviewError = nil
        let payload: [String: Any] = [
            "date": DayflowDB.ymd(target),
            "markdown": body,
        ]

        _Concurrency.Task {
            do {
                let result = try await LLMClient.shared.dailyReview(payload: payload)
                await MainActor.run {
                    self.db.saveReview(date: target, body: result)
                    // Only update the visible review if user is still on the same day
                    if Calendar.current.isDate(self.selectedDate, inSameDayAs: target) {
                        self.reviewBody = result
                    }
                    self.reviewIsLoading = false
                }
            } catch {
                await MainActor.run {
                    self.reviewError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    self.reviewIsLoading = false
                }
            }
        }
    }

    // MARK: - month stats

    struct MonthStats {
        var totalTasks: Int
        var doneTasks: Int
        var openTasks: Int
        var completionRate: Double
        var busiestWeekday: String?
        var longestStreak: Int
        var doneByDay: [String: Int]
        var openByDay: [String: Int]
    }

    func currentMonthStats() -> MonthStats {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: selectedDate)
        guard let monthStart = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
            return MonthStats(totalTasks: 0, doneTasks: 0, openTasks: 0, completionRate: 0,
                              busiestWeekday: nil, longestStreak: 0, doneByDay: [:], openByDay: [:])
        }

        var doneByDay: [String: Int] = [:]
        var openByDay: [String: Int] = [:]
        var totalDone = 0
        var totalOpen = 0

        var cursor = monthStart
        while cursor <= monthEnd {
            let key = DayflowDB.ymd(cursor)
            let body = bodies[key] ?? ""
            let counts = DayflowDB.parseCheckboxes(body)
            doneByDay[key] = counts.done
            openByDay[key] = counts.open
            totalDone += counts.done
            totalOpen += counts.open
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        var localCal = Calendar(identifier: .gregorian)
        localCal.locale = DayflowL10n.activeLocale
        let weekdaySymbols = localCal.shortWeekdaySymbols
        var weekdayCounts: [Int: Int] = [:]
        for (key, count) in doneByDay where count > 0 {
            if let d = DF.ymd.date(from: key) {
                let wd = cal.component(.weekday, from: d)
                weekdayCounts[wd, default: 0] += count
            }
        }
        let busiestKey = weekdayCounts.max { $0.value < $1.value }?.key
        let busiest = busiestKey.flatMap { weekdaySymbols[safe: $0 - 1] }

        var streak = 0
        var maxStreak = 0
        cursor = monthStart
        while cursor <= monthEnd {
            let key = DayflowDB.ymd(cursor)
            if (doneByDay[key] ?? 0) > 0 {
                streak += 1
                maxStreak = max(maxStreak, streak)
            } else {
                streak = 0
            }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        let total = totalDone + totalOpen
        return MonthStats(
            totalTasks: total,
            doneTasks: totalDone,
            openTasks: totalOpen,
            completionRate: total == 0 ? 0 : Double(totalDone) / Double(total),
            busiestWeekday: busiest,
            longestStreak: maxStreak,
            doneByDay: doneByDay,
            openByDay: openByDay
        )
    }
}
