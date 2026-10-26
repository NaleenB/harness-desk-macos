import Foundation

/// Official DeepSeek API rate windows.
///
/// Peak is 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday. Chinese public
/// holidays are not modelled; the UI calls that out in its tooltip.
enum Pricing {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func isPeak(at date: Date) -> Bool {
        let parts = utc.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
            return false
        }
        let minutes = hour * 60 + minute
        let isWeekday = (2...6).contains(weekday) // Monday–Friday
        return isWeekday && ((60..<240).contains(minutes) || (360..<600).contains(minutes))
    }

    /// The next instant at which the window flips, i.e. when the current
    /// peak or off-peak period ends. Boundaries are the only places the
    /// schedule changes, so candidates are the four UTC hours in a day.
    static func nextTransition(after date: Date) -> Date? {
        let calendar = utc
        let startOfDay = calendar.startOfDay(for: date)
        for day in 0...8 {
            guard let base = calendar.date(byAdding: .day, value: day, to: startOfDay) else {
                continue
            }
            for hour in [1, 4, 6, 10] {
                guard let candidate = calendar.date(byAdding: .hour, value: hour, to: base) else {
                    continue
                }
                if candidate <= date { continue }
                let before = candidate.addingTimeInterval(-1)
                if isPeak(at: candidate) != isPeak(at: before) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Compact "2h 31m" / "2d 13h 5m" countdown. Rounds up to the next minute
    /// so the tooltip never claims a period has ended while it is still active.
    static func remainingText(from now: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(now))
        let totalMinutes = Int((seconds / 60).rounded(.up))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        return "\(hours)h \(minutes)m"
    }
}
