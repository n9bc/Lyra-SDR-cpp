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
    /// The last non-zero smoothing the engine reported, restored when averaging comes back on.
    @ObservationIgnored private var lastSmoothing: Int?
    @ObservationIgnored private var capabilityKey: CapabilityKey
    /// The cached band plan, landmarks and spots, and the window and flags they were read for.
    @ObservationIgnored private var overlays = EngineOverlays()
    @ObservationIgnored private var overlayKey: OverlayKey?
    @ObservationIgnored private var lastApply: Date
    @ObservationIgnored private var meterPending = false
    @ObservationIgnored private nonisolated(unsafe) var timer: Timer?

    /// What the overlays depend on: the main window and the display flags.
    private struct OverlayKey: Equatable {
        var centreHz: Int64
        var spanHz: Int64
        var segments: Bool, landmarks: Bool, beacons: Bool, spots: Bool
    }

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
        lastSmoothing = initial.display.smoothing > 0 ? initial.display.smoothing : nil
        tracker.update(running: initial.link.running, p2Running: initial.link.p2Running,
                       datagramsPerSec: initial.link.datagramsPerSec, now: t)
        capabilityKey = CapabilityKey(nnrAvailable: initial.dsp.nnrAvailable,
                                      isP2: initial.link.isP2Rig)
        capabilities = .live(nnrAvailable: initial.dsp.nnrAvailable, isP2: initial.link.isP2Rig)
        lastApply = .distantPast
        snapshot = Self.render(initial, phase: tracker.phase, vfoLocked: false, now: t)
        refreshOverlays(force: false)
        snapshot = Self.render(initial, phase: tracker.phase, vfoLocked: false, now: t, overlays: overlays)

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
        case .disconnect:
            // First, so the drop the disconnect causes is not reported as an error.
            tracker.requestDisconnect()
        default:
            break
        }
        // One batch, one perform: the executor stops at a blocked jump guard itself.
        let calls = LiveCommandPlanner.calls(for: command, state: state, vfoLocked: vfoLocked,
                                                lastSmoothing: lastSmoothing)
        if !calls.isEmpty { facade.perform(calls) }
        if command == .connect {
            // After the perform: connecting may first close a dead earlier attempt, and the
            // engine reports that drop synchronously. It belongs to the old session; the new
            // request starts clean after it.
            tracker.requestConnect(ip: state.link.savedIp, at: now())
        }
        if command == .connect || command == .disconnect { refresh() }
    }

    /// Advances time-based state: connection stall and timeout, deferred meters, the clock.
    func tick() {
        let t = now()
        let before = tracker.phase
        feedTracker(at: t)
        let clockMoved = Self.wholeSecond(t) != snapshot.telemetry.utc
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
        let metersOnly = change.subtracting(.meters).isEmpty
        // Meter ticks (up to 25 Hz) cannot move the display; keep the one already held.
        var fresh = facade.readState(includingDisplay: !metersOnly)
        if metersOnly { fresh.display = state.display }
        state = fresh
        if state.display.smoothing > 0 { lastSmoothing = state.display.smoothing }
        feedTracker(at: t)
        updateCapabilities()
        // Meter ticks never re-read; any other change re-reads only when the key moved or the
        // engine said the overlays changed.
        if !metersOnly { refreshOverlays(force: change.contains(.overlays)) }
        if metersOnly {
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
                       datagramsPerSec: state.link.datagramsPerSec, targetIp: state.link.targetIp,
                       now: t)
    }

    private func updateCapabilities() {
        let key = CapabilityKey(nnrAvailable: state.dsp.nnrAvailable, isP2: state.link.isP2Rig)
        guard key != capabilityKey else { return }
        capabilityKey = key
        capabilities = .live(nnrAvailable: key.nnrAvailable, isP2: key.isP2)
    }

    /// Re-reads the overlays when the key (window and flags) changed, or when `force`d.
    private func refreshOverlays(force: Bool) {
        let d = state.display, r = state.radio
        let key = OverlayKey(
            centreHz: SpectrumGeometry.mainCentreHz(
                rx1Hz: Int64(r.rx1Hz), ritEnabled: r.ritEnabled, ritHz: Int64(r.ritHz),
                ctuneEnabled: r.ctuneEnabled, ctuneCentreHz: Int64(r.ctuneCenterHz)),
            spanHz: Int64(d.spanHz), segments: d.bandPlanSegments, landmarks: d.bandPlanLandmarks,
            beacons: d.bandPlanBeacons, spots: d.showSpots)
        guard force || key != overlayKey else { return }
        overlayKey = key
        let anyShown = key.segments || key.landmarks || key.beacons || key.spots
        overlays = anyShown && key.spanHz > 0
            ? facade.readOverlays(centreHz: key.centreHz, spanHz: key.spanHz) : EngineOverlays()
    }

    private func refresh() { refresh(at: now()) }

    /// Rebuilds the snapshot and assigns it only when it differs, so unchanged state does not
    /// invalidate the views.
    private func refresh(at t: Date) {
        meterPending = false
        lastApply = t
        let next = Self.render(state, phase: tracker.phase, vfoLocked: vfoLocked, now: t, overlays: overlays)
        if next != snapshot { snapshot = next }
    }

    private static func render(_ e: EngineState, phase: ConnectionPhase, vfoLocked: Bool,
                               now: Date, overlays: EngineOverlays = EngineOverlays()) -> RadioSnapshot {
        // The clock shows whole seconds; truncating keeps an identical engine state equal
        // between refreshes inside one second, so the snapshot is not reassigned for nothing.
        LiveSnapshotMapper.snapshot(from: e, phase: phase, vfoLocked: vfoLocked,
                                    now: wholeSecond(now), timeZone: .current, overlays: overlays)
    }

    private static func wholeSecond(_ d: Date) -> Date {
        Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    }
}

extension BackendCapabilities {
    /// What the live backend serves truthfully today. The spectrum, waterfall and spots are the
    /// engine's; the audio terrain is the console's own tap on the received audio. Controls without an engine
    /// path say why they are off.
    nonisolated static func live(nnrAvailable: Bool, isP2: Bool) -> BackendCapabilities {
        let statuses: [BackendFeature: CapabilityStatus] = [
            .connection: .available, .tuning: .available, .receiverDSP: .available,
            .frontEnd: .available, .audio: .available, .transmit: .available,
            .meters: .available, .telemetry: .available, .bands: .available,
            .spectrum: .available, .waterfall: .available, .spots: .available,
            .audioTerrain: .available, .propagation: .mocked, .keyer: .mocked,
            .recorder: .unavailable("Recorder arrives in a later milestone"),
        ]
        var controls: [ConsoleControl: CapabilityStatus] = [:]
        let live: [ConsoleControl] = [
            .connect, .focus, .subReceiver, .copyAB, .swapAB, .split, .ctun, .vfoLock, .rit, .xit,
            .mode, .filterPreset, .bwLock, .band, .agcMode, .audio,
            .displaySettings, .tuningStep, .spectrumTuning, .notches,
        ]
        for c in live { controls[c] = .available }
        for f in DSPFunction.allCases { controls[.dsp(f)] = .available }
        controls[.dsp(.snb)] = .unavailable("The engine has no SNB")
        if !nnrAvailable { controls[.dsp(.nnr)] = .unavailable("NNR model files are not installed") }

        let later = CapabilityStatus.unavailable("Arrives in a later milestone")
        let frontEnd = CapabilityStatus.unavailable("Front-end controls arrive in a later milestone")
        let tx = CapabilityStatus.unavailable(ConsoleAvailability.transmitReason)
        controls[.memory] = .unavailable("Memories arrive in a later milestone")
        controls[.zeroBeat] = .unavailable("Zero beat arrives in a later milestone")
        // The receive edges move by dragging them on the spectrum; the text fields have no write path.
        controls[.filterEdges] = .unavailable("Drag the passband edges on the spectrum to change them")
        controls[.txBandwidth] = tx
        controls[.bandTabs] = .unavailable("Only Ham bands in this version")
        controls[.agcLevels] = .available
        controls[.dspLevels] = .available
        controls[.noiseCapture] = later
        controls[.frontEnd] = frontEnd
        controls[.attenuator] = isP2 ? frontEnd : .unavailable("Hermes-Lite 2 has no attenuator; use LNA")
        controls[.transmit] = tx
        controls[.txDSP] = tx
        controls[.rxEqualizer] = .unavailable("The receive equaliser arrives in a later milestone")
        controls[.profile] = tx
        controls[.tools] = later
        controls[.vfoBandwidth] = .unavailable("Use the filter chips to change the bandwidth")
        return BackendCapabilities(statuses: statuses, controls: controls,
                                   fallback: .unavailable("Not available"))
    }
}
