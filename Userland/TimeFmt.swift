// Time and number formatting helpers (no Foundation available on the kernel).

// MARK: - Civil calendar math (Howard Hinnant's civil-from-days algorithm)

public struct CivilDate {
    public var year: Int, month: Int, day: Int
    public var hour: Int, minute: Int, second: Int
    public var weekday: Int // 0 = Sunday

    public init(epochMs: UInt64) {
        let totalSeconds = epochMs / 1000
        let days = Int(totalSeconds / 86400)
        let secsOfDay = Int(totalSeconds % 86400)
        hour = secsOfDay / 3600
        minute = (secsOfDay % 3600) / 60
        second = secsOfDay % 60
        weekday = (days + 4) % 7 // 1970-01-01 was a Thursday

        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        day = doy - (153 * mp + 2) / 5 + 1
        month = mp < 10 ? mp + 3 : mp - 9
        year = month <= 2 ? y + 1 : y
    }
}

private let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

@inline(__always)
private func twoDigit(_ v: Int) -> String {
    v < 10 ? "0\(v)" : "\(v)"
}

public enum TimeFmt {
    /// "Wed 17:42" — panel clock.
    public static func clock(_ wallMs: UInt64) -> String {
        let d = CivilDate(epochMs: wallMs)
        return "\(weekdayNames[d.weekday]) \(twoDigit(d.hour)):\(twoDigit(d.minute))"
    }

    /// "MMM dd HH:mm" — ls -l style file dates.
    public static func fileDate(_ wallMs: UInt64) -> String {
        let d = CivilDate(epochMs: wallMs)
        return "\(monthNames[d.month - 1]) \(twoDigit(d.day)) \(twoDigit(d.hour)):\(twoDigit(d.minute))"
    }

    /// "Wed Jul 17 17:42:33 UTC 2026" — the `date` command.
    public static func fullDate(_ wallMs: UInt64) -> String {
        let d = CivilDate(epochMs: wallMs)
        return "\(weekdayNames[d.weekday]) \(monthNames[d.month - 1]) \(d.day) " +
               "\(twoDigit(d.hour)):\(twoDigit(d.minute)):\(twoDigit(d.second)) UTC \(d.year)"
    }

    /// "h:mm:ss" — uptime displays.
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return "\(h):\(twoDigit(m)):\(twoDigit(s))"
    }
}

// MARK: - Number formatting (String(format:) replacement)

public enum NumFmt {
    /// Fixed-precision decimal, e.g. fixed(3.14159, 2) == "3.14".
    public static func fixed(_ value: Double, _ decimals: Int) -> String {
        if value != value { return "nan" } // NaN
        let negative = value < 0
        let absV = negative ? -value : value
        var scale = 1
        for _ in 0..<max(0, decimals) { scale *= 10 }
        let scaled = UInt64(absV * Double(scale) + 0.5)
        let whole = scaled / UInt64(scale)
        let frac = scaled % UInt64(scale)
        var out = negative ? "-" : ""
        out += "\(whole)"
        if decimals > 0 {
            out += "."
            var divisor = scale / 10
            while divisor >= 1 {
                out += "\((frac / UInt64(divisor)) % 10)"
                divisor /= 10
            }
        }
        return out
    }

    /// 2-decimal shortcut ("0.42").
    public static func f2(_ value: Double) -> String { fixed(value, 2) }
    /// 1-decimal shortcut ("4.2").
    public static func f1(_ value: Double) -> String { fixed(value, 1) }

    /// Human byte size: "512 B", "4.2 KB", "38 MB".
    public static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return f1(Double(count) / 1024) + " KB" }
        return f1(Double(count) / (1024 * 1024)) + " MB"
    }

    /// Right-align `s` in a field of `width` (space padded).
    public static func right(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return String(repeating: " ", count: width - s.count) + s
    }

    /// Left-align `s` in a field of `width` (space padded, truncated).
    public static func left(_ s: String, _ width: Int) -> String {
        if s.count > width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }
}
