import Foundation
import Observation

/// Meter bridge. P0: mock data only (no C++ linkage yet).
@Observable
final class MeterBridge {
    var sMeterDb: Double = -79.0
    var txPowerW: Double = 0.8
    var swr: Double = 1.0
    var noiseFloorDbm: Double = -120.0
    var rxSnrDb: Double = 24.0

    /// S-meter fill 0...1 from dBm: S0 = -127 dBm to S9+60 = -13 dBm (114 dB span).
    var sMeterLevel: Double { min(max((sMeterDb + 127) / 114, 0), 1) }

    /// S-unit text: S0 = -127 dBm, 6 dB per S-unit, S9 = -73 dBm,
    /// then "S9+10", "S9+20", ... in 10 dB steps. NaN / below S0 -> "S0".
    var sMeterText: String {
        guard sMeterDb.isFinite, sMeterDb >= -127.0 else { return "S0" }
        if sMeterDb >= -73.0 {
            let over = Int(((sMeterDb + 73.0) / 10.0).rounded(.down)) * 10
            return over == 0 ? "S9" : "S9+\(over)"
        }
        let unit = Int(((sMeterDb + 127.0) / 6.0).rounded(.down))
        return "S\(unit)"
    }

    static func mock() -> MeterBridge { MeterBridge() }
}
