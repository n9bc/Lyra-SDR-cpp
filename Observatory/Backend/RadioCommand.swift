import Foundation

/// A request the console makes of the radio. The backend confirms it by publishing a new
/// snapshot; views never assume the change happened.
enum RadioCommand: Equatable, Sendable {
    case focus(ReceiverID)
    case setSubEnabled(Bool)
    case tune(ReceiverID, deltaHz: Int64)
    case connect
    case disconnect
    case setSplit(Bool)
    case copyAToB
    case copyBToA
    case swapAB
    case setRIT(Bool)
    case setXIT(Bool)
    case setCTUN(Bool)
    case setVFOLock(Bool)
    case setMode(ReceiverID, RadioMode)
    case setFilter(ReceiverID, hz: Int)
    case setBandwidthLock(Bool)
    /// The band by the label the console shows ("40").
    case selectBand(String)
    case setAGC(AGCMode)
    case setDSP(DSPFunction, Bool)

    // Spectrum and waterfall gestures (map §4). Frequencies are carriers on the display axis, not
    // dial frequencies; the planner converts with the engine's marker offset and RIT.
    case tuneCarrier(ReceiverID, hz: Int64)
    /// Signed wheel notches (positive tunes up) through the sticky-snap rule.
    case wheelTune(ReceiverID, ticks: Int)
    /// CTUN: slide the locked display centre; positive `deltaHz` drags the spectrum right, which lowers the centre.
    case ctunPan(deltaHz: Int64)
    /// CTUN: move the VFO 1:1 with the cursor.
    case grabVfo(deltaHz: Int64)
    /// Middle or option click: focus Main when Sub is focused, else put VFO B (and Sub) here and focus Sub.
    case spectrumFocusToggle(hz: Int64)
    case setZoom(Double)

    // Display toolbar settings. The engine owns them; the snapshot reports them back.
    /// The wheel step in Hz (Prefs `scrollStepHz`).
    case setWheelStep(Int)
    /// Exact tuning: clicks and wheel never go finer than 100 Hz (Prefs `round100`).
    case setExactTuning(Bool)
    case setPeakHold(PeakHoldSetting)
    /// Spectrum averaging on or off; on restores the last non-zero smoothing.
    case setAveraging(Bool)
    case setBandPlanVisible(Bool)
    case setSpotsVisible(Bool)
    /// One receiver's tuning step in Hz (the STEP chip).
    case setTuningStep(ReceiverID, Int)
}
