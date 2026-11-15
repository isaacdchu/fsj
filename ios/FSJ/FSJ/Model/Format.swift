import Foundation

nonisolated enum Format {
    /// "0.534"
    static func seconds(_ t: Double) -> String {
        String(format: "%.3f", t)
    }

    /// "0.53"
    static func secondsShort(_ t: Double) -> String {
        String(format: "%.2f", t)
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
