import Foundation
import Observation

/// The console's backend over the live engine. Reads engine state through `EngineFacade`, maps
/// it to a `RadioSnapshot`, and turns commands into engine calls. The engine owns the state:
/// nothing is applied optimistically, the snapshot only changes when the engine reports a change
/// (except the console-only VFO lock and the connection phase, which are this backend's own).
@Observable @MainActor
final class LiveRadioBackend: RadioBackend {
    /// Meter changes arrive faster than the console needs; they are applied at most this often.
    nonisolated static let meterInterval: TimeInterval = 0.1

    private(set) var snapshot: RadioSnapshot
    private(set) var capabilities: BackendCapabilities

    @ObservationIgnored private let facade: any EngineFacade
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var state: EngineState
    @ObservationIgnored private var tracker = ConnectionTracker()
    @ObservationIgnored private var vfoLocked = false
    @ObservationIgnored private var capabilityKey: CapabilityKey
    @ObservationIgnored private var lastApply: Date
    @ObservationIgnored private var meterPending = false
    @ObservationIgnored private nonisolated(unsafe) var timer: Timer?

    private struct CapabilityKey: Equatable {
        var nnrAvailable: Bool
        var isP2: Bool
    }

    init(facade: any EngineFacade, now: @escaping @MainActor () -> Date = { Date() },
         startTimer: Bool = true) {
        self.facade = facade
        self.now = now
        let initial = facade.readState()
        let t = now()
        state = initial
        tracker.update(running: initial.link.running, p2Running: initial.link.p2Running,
                       datagramsPerSec: initial.link.datagramsPerSec, now: t)
        capabilityKey = CapabilityKey(nnrAvailable: initial.dsp.nnrAvailable,
                                      isP2: initial.link.isP2Rig)
        capabilities = .live(nnrAvailable: initial.dsp.nnrAvailable, isP2: initial.link.isP2Rig)
        lastApply = .distantPast
        snapshot = Self.render(initial, phase: tracker.phase, vfoLocked: false, now: t)

        facade.observe { [weak self] change in self?.engineChanged(change) }
        if startTimer {
            let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // .common keeps it firing during menu tracking and window resizing.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    deinit { timer?.invalidate() }

    func send(_ command: RadioCommand) {
        switch command {
        case .setVFOLock(let on):
            vfoLocked = on
            refresh()
            return
        case .connect:
            tracker.requestConnect(ip: state.link.savedIp, at: now())
        case .disconnect:
            tracker.requestDisconnect()
        default:
            break
        }
        // One batch, one perform: the executor stops at a blocked jump guard itself.
        let calls = LiveCommandPlanner.calls(for: command, state: state, vfoLocked: vfoLocked)
        if !calls.isEmpty { facade.perform(calls) }
        if command == .connect || command == .disconnect { refresh() }
    }

    /// Advances time-based state: connection stall and timeout, deferred meters, the clock.
    func tick() {
        let t = now()
        let before = tracker.phase
        feedTracker(at: t)
        let clockMoved = Int(t.timeIntervalSince1970) != Int(snapshot.telemetry.utc.timeIntervalSince1970)
        let meterDue = meterPending && t.timeIntervalSince(lastApply) >= Self.meterInterval
        if meterDue || tracker.phase != before || clockMoved { refresh(at: t) }
    }

    func connectOnLaunchIfEnabled() {
        state = facade.readState()
        guard state.link.autoConnectOnLaunch, !state.link.savedIp.isEmpty else { return }
        send(.connect)
    }

    // MARK: - Engine changes

    private func engineChanged(_ change: EngineChange) {
        let t = now()
        state = facade.readState()
        feedTracker(at: t)
        updateCapabilities()
        if change.subtracting(.meters).isEmpty {
            // Meters only: at most one apply per interval; `tick` applies the deferred one.
            if t.timeIntervalSince(lastApply) < Self.meterInterval {
                meterPending = true
                return
            }
        }
        refresh(at: t)
    }

    private func feedTracker(at t: Date) {
        tracker.update(running: state.link.running, p2Running: state.link.p2Running,
                       datagramsPerSec: state.link.datagramsPerSec, now: t)
    }

    private func updateCapabilities() {
        let key = CapabilityKey(nnrAvailable: state.dsp.nnrAvailable, isP2: state.link.isP2Rig)
        guard key != capabilityKey else { return }
        capabilityKey = key
        capabilities = .live(nnrAvailable: key.nnrAvailable, isP2: key.isP2)
    }

    private func refresh() { refresh(at: now()) }

    /// Rebuilds the snapshot and assigns it only when it differs, so unchanged state does not
    /// invalidate the views.
    private func refresh(at t: Date) {
        meterPending = false
        lastApply = t
        let next = Self.render(state, phase: tracker.phase, vfoLocked: vfoLocked, now: t)
        if next != snapshot { snapshot = next }
    }

    private static func render(_ e: EngineState, phase: ConnectionPhase, vfoLocked: Bool,
                               now: Date) -> RadioSnapshot {
        LiveSnapshotMapper.snapshot(from: e, phase: phase, vfoLocked: vfoLocked, now: now,
                                    timeZone: .current)
    }
}

extension BackendCapabilities {
    /// What the live backend serves truthfully today. The spectrum family is still sample data;
    /// controls without an engine path say why they are off.
    nonisolated static func live(nnrAvailable: Bool, isP2: Bool) -> BackendCapabilities {
        let statuses: [BackendFeature: CapabilityStatus] = [
            .connection: .available, .tuning: .available, .receiverDSP: .available,
            .frontEnd: .available, .audio: .available, .transmit: .available,
            .meters: .available, .telemetry: .available, .bands: .available,
            .spectrum: .mocked, .waterfall: .mocked, .audioTerrain: .mocked,
            .propagation: .mocked, .keyer: .mocked,
            .spots: .unavailable("Spots arrive in Milestone 4"),
            .recorder: .unavailable("Recorder arrives in a later milestone"),
        ]
        var controls: [ConsoleControl: CapabilityStatus] = [:]
        let live: [ConsoleControl] = [
            .connect, .focus, .subReceiver, .copyAB, .swapAB, .split, .ctun, .vfoLock, .rit, .xit,
            .mode, .filterPreset, .bwLock, .band, .agcMode,
        ]
        for c in live { controls[c] = .available }
        for f in DSPFunction.allCases { controls[.dsp(f)] = .available }
        controls[.dsp(.snb)] = .unavailable("The engine has no SNB")
        if !nnrAvailable { controls[.dsp(.nnr)] = .unavailable("NNR model files are not installed") }

        let m5 = CapabilityStatus.unavailable("Arrives in Milestone 5")
        let later = CapabilityStatus.unavailable("Arrives in a later milestone")
        let levels = CapabilityStatus.unavailable("DSP levels arrive in Milestone 5")
        let edges = CapabilityStatus.unavailable("Filter edges arrive in Milestone 5")
        let tx = CapabilityStatus.unavailable("Transmit arrives in Milestone 5")
        controls[.memory] = .unavailable("Memories arrive in a later milestone")
        controls[.zeroBeat] = .unavailable("Zero beat needs the live spectrum (Milestone 4)")
        controls[.filterEdges] = edges
        controls[.txBandwidth] = edges
        controls[.bandTabs] = .unavailable("Only Ham bands in this version")
        controls[.agcLevels] = levels
        controls[.dspLevels] = levels
        controls[.noiseCapture] = levels
        controls[.frontEnd] = m5
        controls[.audio] = m5
        controls[.attenuator] = isP2 ? m5 : .unavailable("Hermes-Lite 2 has no attenuator; use LNA")
        controls[.transmit] = tx
        controls[.txDSP] = tx
        controls[.profile] = later
        controls[.tools] = later
        controls[.displaySettings] = .unavailable("Display settings arrive in Milestone 4")
        return BackendCapabilities(statuses: statuses, controls: controls,
                                   fallback: .unavailable("Not available"))
    }
}
