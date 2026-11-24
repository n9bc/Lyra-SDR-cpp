import Foundation

/// The seam between the console and the radio engine. The live implementation wraps the C++
/// engine; tests use a fake. Every call is on the main thread.
/// One band-plan segment as the engine reports it, clipped to the visible window.
struct EngineSegment: Equatable, Sendable {
    var lowHz: Int64
    var highHz: Int64
    /// "CW", "DIG", "CW/DIG", "SSB", "FM", "CH1"..., or "" for a mixed segment.
    var label: String
    var channel: Bool
    /// A channel's QSY frequency (its unclipped low edge).
    var qsyHz: Int64?
}

/// A band-plan landmark ("watering hole" or NCDXF beacon).
struct EngineLandmark: Equatable, Sendable {
    var hz: Int64
    var label: String
    var mode: String
    var beacon: Bool
}

struct EngineSpot: Equatable, Sendable {
    var call: String
    var hz: Int64
    var mine: Bool
    var mode: String
}

extension EngineFacade {
    /// The whole state, display included.
    func readState() -> EngineState { readState(includingDisplay: true) }
}

/// What the engine draws on the frequency axis for one centre and span.
struct EngineOverlays: Equatable, Sendable {
    var segments: [EngineSegment] = []
    var landmarks: [EngineLandmark] = []
    var spots: [EngineSpot] = []
}

@MainActor
protocol EngineFacade: AnyObject {
    /// The engine's state. With `includingDisplay` false the display read (which copies the
    /// waterfall palette) is skipped and `display` is left at its defaults: the caller keeps the
    /// display it already holds, for changes that cannot have moved it (meters only).
    func readState(includingDisplay: Bool) -> EngineState
    /// Band-plan segments, landmarks and spots in the window `centreHz` +/- `spanHz` / 2. It is
    /// allocation-heavy, so callers re-read only when the window or a display flag changes.
    func readOverlays(centreHz: Int64, spanHz: Int64) -> EngineOverlays
    /// Registers the one change handler.
    func observe(_ onChange: @escaping @MainActor (EngineChange) -> Void)
    func perform(_ calls: [EngineCall])
    /// Moves the locked CTUN display centre (`HL2Stream::setCtuneCenterHz`).
    func setCtuneCenter(_ hz: UInt32)
    /// Writes the zoom preference the engine's zoom binding follows (`Prefs::setZoom`).
    func setZoomPreference(_ zoom: Double)
    func setScrollStepPreference(_ hz: Int)
    func setRound100Preference(_ on: Bool)
    func setPeakPreference(enabled: Bool, secs: Double)
    func setSmoothingPreference(_ value: Int)
    func setBandPlanSegmentsPreference(_ on: Bool)
    func setShowSpotsPreference(_ on: Bool)
    func setStepPreference(_ receiver: ReceiverID, hz: Int)
    func quitApplication()
}
