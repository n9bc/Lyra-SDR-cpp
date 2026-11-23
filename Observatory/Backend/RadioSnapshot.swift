import Foundation

// MARK: - Enums

enum RadioMode: String, CaseIterable, Sendable {
    case lsb = "LSB", usb = "USB", cwl = "CWL", cwu = "CWU", dsb = "DSB"
    case am = "AM", sam = "SAM", fm = "FM", digl = "DIGL", digu = "DIGU"
}

enum AGCMode: String, CaseIterable, Sendable {
    case off = "Off", fast = "Fast", med = "Med", slow = "Slow"
}

extension RadioMode {
    /// The mode after this one in `allCases` order, wrapping at the end.
    nonisolated var next: RadioMode {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

extension AGCMode {
    /// Off, Fast, Med, Slow, then back to Off.
    nonisolated var next: AGCMode {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

enum ConnectionPhase: Equatable, Sendable {
    case disconnected, discovering, connecting, socketOpen, streaming, stalled
    case error(String)

    /// The command the power control sends: connect while offline or failed, otherwise disconnect.
    nonisolated var powerCommand: RadioCommand {
        switch self {
        case .disconnected, .error: .connect
        default: .disconnect
        }
    }
}

enum TransmitState: Equatable, Sendable {
    case idle, requested, onAir, releasing
    case blocked(String)
}

enum ReceiverID: Equatable, Sendable { case main, sub }

enum BandPlanKind: Equatable, Sendable { case digital, ft8, phoneExtra, phoneGeneral, phoneAll }

enum SpotKind: Equatable, Sendable { case dx, watering, own }

enum TerrainView: String, CaseIterable, Sendable {
    case threeD = "3D", waterfall = "Waterfall", both = "Both"
}

enum PropagationQuality: String, Equatable, Sendable {
    case good = "Good", fair = "Fair", poor = "Poor"
}

// MARK: - Sub-structs

struct QuickToggle: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var isOn: Bool
}

struct ConnectionSnapshot: Equatable, Sendable {
    var phase: ConnectionPhase
    var radioName: String
    var address: String
    var sampleRateHz: Int
    var protocolVersion: Int
}

struct ReceiverSnapshot: Equatable, Sendable {
    var id: ReceiverID
    var enabled: Bool
    var frequencyHz: Int64
    var mode: RadioMode
    var filterHz: Int
    var stepHz: Int
    var bandName: String
    var antenna: String
    var signalDbm: Double
    var snrDb: Double?
    var agc: AGCMode
    var ritEnabled: Bool
    var ritOffsetHz: Int
    var xitEnabled: Bool
    var xitOffsetHz: Int
    var splitTx: Bool
    var isTxVFO: Bool
    var quickToggles: [QuickToggle]
}

struct FrontEndSnapshot: Equatable, Sendable {
    var lnaDb: Int
    var lnaRange: ClosedRange<Int>
    var autoLna: Bool
    var overload: Bool
    var inputs: [String]
    var selectedInput: String
}

struct AudioSnapshot: Equatable, Sendable {
    var afGainDb: Double
    var volume: Double
    var muted: Bool
    var volume2: Double
    var muted2: Bool
    var balance: Double
    var outputDevice: String
    var binaural: Bool
    var monitorTx: Bool
}

struct DSPSnapshot: Equatable, Sendable {
    var toggles: [QuickToggle]
    var nrMode: Int
    var anfLevel: Int
    var nbLevel: Int
    var agcThresholdDbfs: Int
    var agcGainDb: Int
    var notchCount: Int
    var squelchOn: Bool
}

struct BandSnapshot: Equatable, Sendable {
    var tabs: [String]
    var selectedTab: String
    var bands: [String]
    var selectedBand: String
}

struct FilterSnapshot: Equatable, Sendable {
    var rxLowHz: Int
    var txLowHz: Int
    var bwLocked: Bool
    var txBandwidthLabel: String
}

struct BandPlanSegment: Equatable, Sendable {
    var lowHz: Int64
    var highHz: Int64
    var label: String
    var kind: BandPlanKind
}

struct Spot: Identifiable, Equatable, Sendable {
    var id: String { call }
    var call: String
    var frequencyHz: Int64
    var kind: SpotKind
}

struct DisplaySnapshot: Equatable, Sendable {
    var spanLowHz: Int64
    var spanHighHz: Int64
    /// The Sub receiver's own span; the engine tracks one per receiver.
    var subSpanLowHz: Int64
    var subSpanHighHz: Int64
    var zoom: Double
    var wheelStepHz: Int
    var peakHold: String
    var averaging: Bool
    var bandPlanVisible: Bool
    var bandPlan: [BandPlanSegment]
    var spots: [Spot]

    /// The display as seen by one receiver. Sub gets its own span, and the band plan and
    /// spots (which are for the Main receiver's band) are dropped.
    func view(for id: ReceiverID) -> DisplaySnapshot {
        guard id == .sub else { return self }
        var v = self
        v.spanLowHz = subSpanLowHz
        v.spanHighHz = subSpanHighHz
        v.bandPlan = []
        v.spots = []
        return v
    }
}

struct BandCondition: Equatable, Sendable {
    var band: String
    var quality: PropagationQuality
}

struct PropagationSnapshot: Equatable, Sendable {
    var sfi: Int
    var aIndex: Int
    var kIndex: Int
    var bands: [BandCondition]
}

struct TransmitSnapshot: Equatable, Sendable {
    var state: TransmitState
    var drivePct: Int
    var tunePct: Int
    var micGainDb: Double
    var monitorLevel: Double
    var voxEnabled: Bool
    var attOnTx: Bool
    var swrProtectArmed: Bool
    var paCapture: Bool
    var psEnabled: Bool
    var psFeedback: Int?
    var fwdPowerW: Double?
    var swr: Double?
    var alcDb: Double?
    var micLevelDb: Double?
}

struct KeyerClip: Identifiable, Equatable, Sendable {
    var id: String { key }
    var key: String
    var name: String
}

struct KeyerSnapshot: Equatable, Sendable {
    var title: String
    var clips: [KeyerClip]
    var txEnabled: Bool
}

struct TelemetrySnapshot: Equatable, Sendable {
    var temperatureC: Double?
    var supplyV: Double?
    var paCurrentA: Double?
    var cpuPct: Int?
    var tciClients: Int?
    var utc: Date
    var timeZone: TimeZone
    var graphics: String?
}

struct SessionSnapshot: Equatable, Sendable {
    var profileName: String
    var profileModified: Bool
    var recordingElapsed: TimeInterval?
    var lastSpot: String?
    var txDSPOn: [String: Bool]
    var tools: [String]
    var statusMessage: String
    var ctunEnabled: Bool
    var vfoLocked: Bool
    var focused: ReceiverID
}

// MARK: - Root

struct RadioSnapshot: Equatable, Sendable {
    var connection: ConnectionSnapshot
    var main: ReceiverSnapshot
    var sub: ReceiverSnapshot
    var frontEnd: FrontEndSnapshot
    var audio: AudioSnapshot
    var dsp: DSPSnapshot
    var band: BandSnapshot
    var filter: FilterSnapshot
    var display: DisplaySnapshot
    var propagation: PropagationSnapshot
    var transmit: TransmitSnapshot
    var keyer: KeyerSnapshot
    var telemetry: TelemetrySnapshot
    var session: SessionSnapshot

    func receiver(_ id: ReceiverID) -> ReceiverSnapshot { id == .main ? main : sub }
    var focusedReceiver: ReceiverSnapshot { receiver(session.focused) }
}

// MARK: - Sample data (approved mockup values)

extension RadioSnapshot {
    private static func toggles(_ labels: [String], on: Set<String>) -> [QuickToggle] {
        labels.map { label in
            QuickToggle(id: String(label.split(separator: " ").first ?? ""), label: label,
                        isOn: on.contains(label))
        }
    }

    static let sample = RadioSnapshot(
        connection: ConnectionSnapshot(
            phase: .streaming, radioName: "Hermes-Lite 2 v74.2", address: "169.254.19.221",
            sampleRateHz: 192_000, protocolVersion: 1),
        main: ReceiverSnapshot(
            id: .main, enabled: true, frequencyHz: 7_128_500, mode: .lsb, filterHz: 2700,
            stepHz: 100, bandName: "40M", antenna: "RF1", signalDbm: -63.2, snrDb: 24, agc: .med,
            ritEnabled: true, ritOffsetHz: 120, xitEnabled: false, xitOffsetHz: 0,
            splitTx: false, isTxVFO: true,
            quickToggles: toggles(
                ["ATT", "LNA +20", "AUTO", "NB", "NR 2", "ANF", "NOTCH 2", "SQ", "APF", "BIN"],
                on: ["LNA +20", "AUTO", "NR 2", "ANF", "NOTCH 2"])),
        sub: ReceiverSnapshot(
            id: .sub, enabled: false, frequencyHz: 14_195_000, mode: .usb, filterHz: 2700,
            stepHz: 100, bandName: "20M", antenna: "RF1", signalDbm: -140, snrDb: nil, agc: .med,
            ritEnabled: false, ritOffsetHz: 0, xitEnabled: false, xitOffsetHz: 0,
            splitTx: false, isTxVFO: false,
            quickToggles: toggles(["ATT", "LNA +20", "NB", "NR", "ANF", "NOTCH", "SQ", "APF"], on: [])),
        frontEnd: FrontEndSnapshot(
            lnaDb: 20, lnaRange: -12...48, autoLna: true, overload: false,
            inputs: ["RF1", "Alt"], selectedInput: "RF1"),
        audio: AudioSnapshot(
            afGainDb: 12, volume: 0.62, muted: false, volume2: 0.50, muted2: false, balance: 0.0,
            outputDevice: "MacBook Pro Speakers", binaural: false, monitorTx: false),
        dsp: DSPSnapshot(
            toggles: toggles(
                ["NB", "BIN", "NR", "NNR", "ANF", "LMS", "SQ", "APF", "NF 2", "SNB"],
                on: ["NR", "ANF", "NF 2"]),
            nrMode: 2, anfLevel: 40, nbLevel: 30, agcThresholdDbfs: -92, agcGainDb: 88,
            notchCount: 2, squelchOn: false),
        band: BandSnapshot(
            tabs: ["Ham", "BC", "Gen", "Time", "Xvtr", "Mem"], selectedTab: "Ham",
            bands: ["160", "80", "60", "40", "30", "20", "17", "15", "12", "10", "6", "WWV"],
            selectedBand: "40"),
        filter: FilterSnapshot(
            rxLowHz: 100, txLowHz: 100, bwLocked: true,
            txBandwidthLabel: "2.7 kHz"),
        display: DisplaySnapshot(
            spanLowHz: 7_060_000, spanHighHz: 7_200_000,
            subSpanLowHz: 14_125_000, subSpanHighHz: 14_265_000, zoom: 2.0, wheelStepHz: 500,
            peakHold: "2 s", averaging: true, bandPlanVisible: true,
            bandPlan: [
                BandPlanSegment(lowHz: 7_060_000, highHz: 7_074_000, label: "Digital", kind: .digital),
                BandPlanSegment(lowHz: 7_074_000, highHz: 7_080_000, label: "FT8", kind: .ft8),
                BandPlanSegment(lowHz: 7_080_000, highHz: 7_125_000, label: "Phone · Extra", kind: .phoneExtra),
                BandPlanSegment(lowHz: 7_125_000, highHz: 7_175_000, label: "Phone · General", kind: .phoneGeneral),
                BandPlanSegment(lowHz: 7_175_000, highHz: 7_200_000, label: "Phone · all", kind: .phoneAll),
            ],
            spots: [
                Spot(call: "LA7TN", frequencyHz: 7_085_500, kind: .dx),
                Spot(call: "FT8", frequencyHz: 7_074_500, kind: .watering),
                Spot(call: "IQ2CF", frequencyHz: 7_100_300, kind: .dx),
                Spot(call: "EA3BDE", frequencyHz: 7_137_200, kind: .own),
                Spot(call: "MM7CEH", frequencyHz: 7_163_000, kind: .dx),
                Spot(call: "G0AKH/P", frequencyHz: 7_176_000, kind: .dx),
                Spot(call: "S52DC", frequencyHz: 7_188_000, kind: .dx),
            ]),
        propagation: PropagationSnapshot(
            sfi: 142, aIndex: 8, kIndex: 2,
            bands: [
                BandCondition(band: "80", quality: .good), BandCondition(band: "40", quality: .good),
                BandCondition(band: "30", quality: .good), BandCondition(band: "160", quality: .good),
                BandCondition(band: "20", quality: .fair), BandCondition(band: "17", quality: .fair),
                BandCondition(band: "15", quality: .fair), BandCondition(band: "12", quality: .poor),
                BandCondition(band: "10", quality: .poor), BandCondition(band: "6", quality: .poor),
            ]),
        transmit: TransmitSnapshot(
            state: .idle, drivePct: 100, tunePct: 50, micGainDb: -5, monitorLevel: 0.40,
            voxEnabled: true, attOnTx: false, swrProtectArmed: true, paCapture: false,
            psEnabled: true, psFeedback: 154, fwdPowerW: 0, swr: 1.00, alcDb: -30, micLevelDb: -40),
        keyer: KeyerSnapshot(
            title: "Voice keyer",
            clips: [
                KeyerClip(key: "F1", name: "CQ contest"), KeyerClip(key: "F2", name: "CQ DX"),
                KeyerClip(key: "F3", name: "QRZ?"), KeyerClip(key: "F4", name: "Callsign"),
                KeyerClip(key: "F5", name: "Name and QTH"), KeyerClip(key: "F6", name: "Thanks, 73"),
            ],
            txEnabled: true),
        telemetry: TelemetrySnapshot(
            temperatureC: 31.4, supplyV: nil, paCurrentA: 0.00, cpuPct: 6, tciClients: 2,
            // 2026-11-23 09:17:29 UTC
            utc: Date(timeIntervalSince1970: 1_795_425_449),
            timeZone: TimeZone(identifier: "Europe/Oslo")!, graphics: "Metal · 120 fps"),
        session: SessionSnapshot(
            profileName: "SSB working", profileModified: true, recordingElapsed: 761,
            lastSpot: "EA3BDE 7.137",
            txDSPOn: ["Speech": true, "EQ": true, "Combinator": false, "Plating": false, "RX EQ": false],
            tools: ["Tuner", "CW Decoder", "QSO", "eSSB", "PureSignal", "Amp", "Diversity", "QRV",
                    "Freq cal"],
            statusMessage: "Tuned to 7.128 500 LSB", ctunEnabled: true, vfoLocked: false,
            focused: .main))
}
