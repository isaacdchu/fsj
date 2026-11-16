import Foundation

nonisolated enum Format {
    /// Seconds to whole milliseconds: 0.534 -> "534".
    static func ms(_ seconds: Double) -> String {
        String(Int((seconds * 1000).rounded()))
    }

    /// Seconds to milliseconds with one decimal: 0.01708 -> "17.1".
    static func msTenths(_ seconds: Double) -> String {
        String(format: "%.1f", seconds * 1000)
    }

    /// "00:03.4" for the recording timer.
    static func timer(_ elapsed: TimeInterval) -> String {
        let t = Swift.max(0, elapsed)
        let minutes = Int(t / 60)
        let seconds = t - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    /// "Today, 6:03 PM" or "Nov 12, 6:03 PM".
    static func jumpDate(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today, \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// "1 attempt", "12 attempts"
    static func attempts(_ n: Int) -> String {
        n == 1 ? "1 attempt" : "\(n) attempts"
    }
}
