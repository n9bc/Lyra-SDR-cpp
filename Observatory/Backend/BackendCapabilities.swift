import Foundation

/// How truthfully a backend can serve a feature. The console reads this to decide
/// whether to show the "Sample data" badge.
enum CapabilityStatus: Equatable, Sendable {
    case available
    case mocked
    case unavailable(String)
}

enum BackendFeature: CaseIterable, Sendable {
    case connection, tuning, receiverDSP, audio, frontEnd, transmit, spectrum, waterfall
    case audioTerrain, meters, telemetry, bands, propagation, keyer, recorder, spots
}

extension BackendFeature {
    /// Lowercase name used in the "Partly sample" tooltip.
    nonisolated var displayName: String {
        switch self {
        case .connection: "connection"
        case .tuning: "tuning"
        case .receiverDSP: "receiver dsp"
        case .audio: "audio"
        case .frontEnd: "front end"
        case .transmit: "transmit"
        case .spectrum: "spectrum"
        case .waterfall: "waterfall"
        case .audioTerrain: "audio terrain"
        case .meters: "meters"
        case .telemetry: "telemetry"
        case .bands: "bands"
        case .propagation: "propagation"
        case .keyer: "keyer"
        case .recorder: "recorder"
        case .spots: "spots"
        }
    }
}

enum DSPFunction: String, CaseIterable, Sendable {
    case nb = "NB", bin = "BIN", nr = "NR", nnr = "NNR", anf = "ANF"
    case lms = "LMS", sq = "SQ", apf = "APF", nf = "NF", snb = "SNB"
}

/// One console control whose availability the backend reports individually.
enum ConsoleControl: Hashable, Sendable {
    case connect, focus, subReceiver, copyAB, swapAB, memory, split, ctun, vfoLock, rit, xit, zeroBeat
    case mode, filterPreset, bwLock, filterEdges, txBandwidth, bandTabs, band
    case agcMode, agcLevels, dsp(DSPFunction), dspLevels, noiseCapture
    case frontEnd, attenuator, audio, transmit, txDSP, profile, tools, displaySettings
}

struct BackendCapabilities: Equatable, Sendable {
    private let statuses: [BackendFeature: CapabilityStatus]
    private let controls: [ConsoleControl: CapabilityStatus]
    private let fallback: CapabilityStatus

    init(statuses: [BackendFeature: CapabilityStatus] = [:],
         controls: [ConsoleControl: CapabilityStatus] = [:], fallback: CapabilityStatus) {
        self.statuses = statuses
        self.controls = controls
        self.fallback = fallback
    }

    func status(_ f: BackendFeature) -> CapabilityStatus { statuses[f] ?? fallback }

    /// Availability of one control; controls without an entry take the fallback.
    func control(_ c: ConsoleControl) -> CapabilityStatus { controls[c] ?? fallback }

    /// Features served from sample data, in `BackendFeature.allCases` order.
    var mockedFeatures: [BackendFeature] {
        BackendFeature.allCases.filter { status($0) == .mocked }
    }

    /// True when any feature is served from sample data.
    var isSampleData: Bool {
        BackendFeature.allCases.contains { status($0) == .mocked }
    }

    static let allMocked = BackendCapabilities(fallback: .mocked)
}
