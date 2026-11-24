import Foundation
import Observation

/// Serves sample data and applies commands to it, standing in for the engine's
/// confirmation. Every capability is `.mocked`, so the console labels it as such.
@Observable @MainActor
final class MockRadioBackend: RadioBackend {
    @ObservationIgnored let capabilities: BackendCapabilities = .allMocked
    private(set) var snapshot: RadioSnapshot

    init(snapshot: RadioSnapshot = .sample) {
        self.snapshot = snapshot
    }

    func send(_ command: RadioCommand) {
        snapshot = Self.applying(command, to: snapshot)
    }

    /// The mock's stand-in for engine behaviour: what the snapshot becomes after `command`.
    nonisolated static func applying(_ command: RadioCommand, to s: RadioSnapshot) -> RadioSnapshot {
        var s = s
        switch command {
        case .focus(let id):
            guard id == .main || s.sub.enabled else { return s }
            s.session.focused = id
        case .setSubEnabled(let on):
            s.sub.enabled = on
            if !on && s.session.focused == .sub { s.session.focused = .main }
        case .tune(let id, let delta):
            guard !s.session.vfoLocked, s.receiver(id).enabled else { return s }
            retune(&s, id, to: s.receiver(id).frequencyHz + delta)
            announceTuning(&s, id)
        case .connect:
            s.connection.phase = .streaming
        case .disconnect:
            s.connection.phase = .disconnected
        case .setSplit(let on):
            s.main.splitTx = on; s.sub.splitTx = on
            s.main.isTxVFO = !on; s.sub.isTxVFO = on
        case .copyAToB:
            guard !s.session.vfoLocked else { return s }
            retune(&s, .sub, to: s.main.frequencyHz)
        case .copyBToA:
            guard !s.session.vfoLocked else { return s }
            retune(&s, .main, to: s.sub.frequencyHz)
        case .swapAB:
            guard !s.session.vfoLocked else { return s }
            let (a, b) = (s.main.frequencyHz, s.sub.frequencyHz)
            retune(&s, .main, to: b)
            retune(&s, .sub, to: a)
        case .setRIT(let on): s.main.ritEnabled = on
        case .setXIT(let on): s.main.xitEnabled = on
        case .setCTUN(let on): s.session.ctunEnabled = on
        case .setVFOLock(let on): s.session.vfoLocked = on
        case .setMode(let id, let mode):
            if id == .main { s.main.mode = mode } else { s.sub.mode = mode }
        case .setFilter(let id, let hz):
            if id == .main { s.main.filterHz = hz } else { s.sub.filterHz = hz }
        case .setBandwidthLock(let on): s.filter.bwLocked = on
        case .selectBand(let label):
            guard !s.session.vfoLocked, let hz = bandDefaults[label] else { return s }
            let id = s.session.focused
            s.band.selectedBand = label
            retune(&s, id, to: hz)
            let name = Int(label) != nil ? label + "M" : label
            if id == .main { s.main.bandName = name } else { s.sub.bandName = name }
            announceTuning(&s, id)
        case .setAGC(let mode):
            s.main.agc = mode; s.sub.agc = mode
        case .setDSP(let function, let on):
            if let i = s.dsp.toggles.firstIndex(where: { $0.id == function.rawValue }) {
                s.dsp.toggles[i].isOn = on
            }
            // The quick toggles call the notch "NOTCH"; every other id matches the function.
            let quickID = function == .nf ? "NOTCH" : function.rawValue
            for i in s.main.quickToggles.indices where s.main.quickToggles[i].id == quickID {
                s.main.quickToggles[i].isOn = on
            }
            for i in s.sub.quickToggles.indices where s.sub.quickToggles[i].id == quickID {
                s.sub.quickToggles[i].isOn = on
            }
            if function == .sq { s.dsp.squelchOn = on }
        }
        refreshOverlays(&s)
        return s
    }

    /// Keeps the sample's VFO lines and passbands on the receivers' frequencies, modes and filters.
    private nonisolated static func refreshOverlays(_ s: inout RadioSnapshot) {
        func passband(_ r: ReceiverSnapshot) -> ClosedRange<Int64> {
            let f = r.frequencyHz, bw = Int64(r.filterHz)
            switch r.mode {
            case .lsb, .cwl, .digl: return (f - bw)...f
            case .am, .sam, .dsb, .fm: return (f - bw / 2)...(f + bw / 2)
            case .usb, .cwu, .digu: return f...(f + bw)
            }
        }
        s.display.mainCarrierHz = s.main.frequencyHz
        s.display.mainPassband = passband(s.main)
        s.display.subCarrierHz = s.sub.frequencyHz
        s.display.subPassband = passband(s.sub)
    }

    /// Where each band's button tunes the mock.
    private nonisolated static let bandDefaults: [String: Int64] = [
        "160": 1_840_000, "80": 3_700_000, "60": 5_357_000, "40": 7_150_000, "30": 10_120_000,
        "20": 14_200_000, "17": 18_120_000, "15": 21_200_000, "12": 24_940_000, "10": 28_500_000,
        "6": 50_150_000, "WWV": 10_000_000,
    ]

    /// Sets one receiver's frequency (never below 0), moving its span to keep it in view.
    private nonisolated static func retune(_ s: inout RadioSnapshot, _ id: ReceiverID, to hz: Int64) {
        let f = max(0, hz)
        var low = id == .main ? s.display.spanLowHz : s.display.subSpanLowHz
        var high = id == .main ? s.display.spanHighHz : s.display.subSpanHighHz
        if f < low || f > high {
            let width = high - low
            low = max(0, f - width / 2)
            high = low + width
        }
        if id == .main {
            s.main.frequencyHz = f
            s.display.spanLowHz = low; s.display.spanHighHz = high
        } else {
            s.sub.frequencyHz = f
            s.display.subSpanLowHz = low; s.display.subSpanHighHz = high
        }
    }

    private nonisolated static func announceTuning(_ s: inout RadioSnapshot, _ id: ReceiverID) {
        let r = s.receiver(id)
        s.session.statusMessage = "Tuned to \(ConsoleFormat.frequency(r.frequencyHz)) \(r.mode.rawValue)"
    }
}
