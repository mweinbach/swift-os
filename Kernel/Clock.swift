// Kernel clock: ARM generic timer counter -> uptime.

enum Clock {
    static private(set) var frequency: UInt64 = 62_500_000

    static func initClock() {
        let f = armReadCntfrq()
        if f != 0 { frequency = f }
    }

    static var uptimeTicks: UInt64 { armReadCntpct() }

    static var uptimeMs: UInt64 { armReadCntpct() * 1000 / frequency }

    /// Seconds as Double, matching the old `TimeInterval`-based APIs.
    static var uptimeSeconds: Double { Double(uptimeMs) / 1000.0 }
}
