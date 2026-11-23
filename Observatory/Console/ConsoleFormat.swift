import Foundation

/// Pure text formatting for the console readouts (VFO, status bar, transmit deck).
enum ConsoleFormat {
    nonisolated private static let minus = "\u{2212}"

    /// "7.128.500": MHz.kHz.Hz groups separated by dots, no leading zeros on the MHz group.
    nonisolated static func frequency(_ hz: Int64) -> String {
        let v = max(hz, 0)
        let mhz = v / 1_000_000
        let khz = (v / 1_000) % 1_000
        let sub = v % 1_000
        return "\(mhz)." + String(format: "%03d.%03d", Int(khz), Int(sub))
    }

    /// S9 = -73 dBm, 6 dB per S-unit below, "S9+N" (N in 10 dB steps, clamped to 60) above.
    nonisolated static func sUnits(dbm: Double) -> String {
        guard !dbm.isNaN else { return "S0" }
        let over = dbm + 73
        if over >= 5 {
            let n = min((over / 10).rounded() * 10, 60)
            return "S9+\(Int(n))"
        }
        let s = min(max((9 + over / 6).rounded(), 0), 9)
        return "S\(Int(s))"
    }

    /// Same scale as the S-meter control; delegates rather than duplicating the mapping.
    nonisolated static func meterFraction(dbm: Double) -> Double {
        LyraSMeter.fraction(dbm: dbm)
    }

    /// Signed offset in kHz with two decimals, e.g. "+0.12 kHz".
    nonisolated static func offsetKHz(_ hz: Int) -> String {
        let body = String(format: "%.2f", abs(Double(hz)) / 1_000)
        return (hz < 0 ? minus : "+") + body + " kHz"
    }

    /// "+12 dB", "−5 dB" (U+2212), "0 dB". Non-finite input (NaN, ±inf) yields the placeholder "— dB".
    nonisolated static func signedDb(_ db: Double) -> String {
        guard db.isFinite else { return "\u{2014} dB" }
        let r = Int(min(max(db.rounded(), -1e9), 1e9))
        if r == 0 { return "0 dB" }
        return (r < 0 ? minus : "+") + "\(abs(r)) dB"
    }

    /// Header detail for sections that follow the focused receiver: Sub is prefixed so it is never mistaken for Main.
    nonisolated static func focusDetail(_ detail: String, focused: ReceiverID) -> String {
        focused == .sub ? "SUB \u{00B7} " + detail : detail
    }

    nonisolated static func telemetry(volts: Double?) -> String {
        guard let volts else { return "not reported" }
        return String(format: "%.1f V", volts)
    }

    /// "09:17:29Z" for UTC, "10:17:29" for local time in `tz`.
    nonisolated static func clock(_ date: Date, in tz: TimeZone, utc: Bool) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc ? .gmt : tz
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let text = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return utc ? text + "Z" : text
    }
}

enum SegmentZone: Equatable { case normal, over }

/// Maps a 0...1 meter fraction to lit segments and per-segment colour zones.
struct SegmentMeterModel {
    let count: Int

    nonisolated static let overStart = 0.6

    nonisolated func litCount(fraction: Double) -> Int {
        guard !fraction.isNaN else { return 0 }
        let f = min(max(fraction, 0), 1)
        return min(max(Int((f * Double(count)).rounded()), 0), count)
    }

    nonisolated func zone(at index: Int) -> SegmentZone {
        Double(index) / Double(count) >= Self.overStart ? .over : .normal
    }
}
