import Foundation

/// Official DeepSeek API rate windows.
///
/// Peak is 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday. Chinese public
/// holidays are not modelled; the UI calls that out in its tooltip.
enum Pricing {
    static func isPeak(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
            return false
        }
        let minutes = hour * 60 + minute
        let isWeekday = (2...6).contains(weekday) // Monday–Friday
        return isWeekday && ((60..<240).contains(minutes) || (360..<600).contains(minutes))
    }
}
