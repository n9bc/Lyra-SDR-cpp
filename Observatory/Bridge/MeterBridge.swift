import Foundation
import Observation

/// Meter bridge. With a facade, S-meter values mirror the backend's
/// pre-computed `MeterModel` output; without one (`mock()`), they are derived
/// from `sMeterDb`.
@MainActor
@Observable
final class MeterBridge {
    /// Mock input. Setting it derives `sMeterLevel`, `sMeterText` and `dbmText`.
    /// Unused in facade mode (the backend does not expose raw dBm).
    var sMeterDb: Double = -79.0 {
        didSet { if facade == nil { deriveFromDb() } }
    }
    /// S-meter fill 0...1 (backend-normalised in facade mode).
    var sMeterLevel: Double = 0
    var sMeterPeak: Double = 0
    /// S-unit text ("S9", "S9+20").
    var sMeterText: String = "S0"
    /// dBm readout ("-53 dBm").
    var dbmText: String = ""
    /// 0...1 position of S9 on the S-meter scale.
    var normAtS9: Double = 73.0 / 114.0
    var txPowerW: Double = 0.8
    var swr: Double = 1.0
    var noiseFloorDbm: Double = -120.0
    var rxSnrDb: Double = 24.0

    @ObservationIgnored private let facade: (any MeterFacade)?

    private init(facade: (any MeterFacade)?) {
        self.facade = facade
        if facade == nil { deriveFromDb() }
    }

    /// Standalone instance with local state (SPM builds, tests, previews).
    static func mock() -> MeterBridge { MeterBridge(facade: nil) }

    /// Live instance mirroring `facade`.
    convenience init(facade: some MeterFacade) {
        self.init(facade: Optional(facade))
        sync(from: facade)
        facade.observeMeter { [weak self, weak facade] in
            guard let self, let facade else { return }
            self.sync(from: facade)
        }
    }

    private func sync(from f: any MeterFacade) {
        sMeterLevel = f.meterLevel
        sMeterPeak = f.meterPeak
        sMeterText = f.meterText
        dbmText = f.meterDbmText
        normAtS9 = f.meterNormAtS9
        swr = f.liveSwr
        noiseFloorDbm = f.noiseFloorDbm
        rxSnrDb = f.rxSnrDb
    }

    private func deriveFromDb() {
        sMeterLevel = Self.level(forDb: sMeterDb)
        sMeterText = Self.text(forDb: sMeterDb)
        dbmText = sMeterDb.isFinite ? String(format: "%.0f dBm", sMeterDb) : ""
    }

    /// S-meter fill 0...1 from dBm: S0 = -127 dBm to S9+60 = -13 dBm (114 dB span).
    static func level(forDb db: Double) -> Double { min(max((db + 127) / 114, 0), 1) }

    /// S-unit text: S0 = -127 dBm, 6 dB per S-unit, S9 = -73 dBm,
    /// then "S9+10", "S9+20", ... in 10 dB steps. NaN / below S0 -> "S0".
    static func text(forDb db: Double) -> String {
        guard db.isFinite, db >= -127.0 else { return "S0" }
        if db >= -73.0 {
            let over = Int(((db + 73.0) / 10.0).rounded(.down)) * 10
            return over == 0 ? "S9" : "S9+\(over)"
        }
        let unit = Int(((db + 127.0) / 6.0).rounded(.down))
        return "S\(unit)"
    }
}
