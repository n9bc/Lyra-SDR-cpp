import Foundation

/// Which groups of engine state changed, so the backend re-reads only what it needs.
struct EngineChange: OptionSet, Sendable {
    let rawValue: Int
    static let radio = EngineChange(rawValue: 1 << 0)
    static let dsp = EngineChange(rawValue: 1 << 1)
    static let audio = EngineChange(rawValue: 1 << 2)
    static let meters = EngineChange(rawValue: 1 << 3)
    static let stats = EngineChange(rawValue: 1 << 4)
    static let session = EngineChange(rawValue: 1 << 5)
    /// Spots or the band-plan preferences changed.
    static let overlays = EngineChange(rawValue: 1 << 6)
}

/// One engine call. The command planner turns a `RadioCommand` into a list of these and the
/// facade executes them in order on the main thread.
enum EngineCall: Equatable, Sendable {
    case connect, disconnect
    /// The facade evaluates `HL2Stream::txBlocksJumpFrom`; when it returns true the rest of the
    /// batch is skipped.
    case requireJumpAllowed(fromHz: UInt32, toHz: UInt32)
    case stopTxForBlockedJump
    case setRx1Hz(UInt32), setRx2Hz(UInt32), setVfoBHz(UInt32)
    case setSubEnabled(Bool), setFocusedRx(Int), setSplitEnabled(Bool), setRptActive(Bool)
    case setRitEnabled(Bool), setXitEnabled(Bool), setCtuneEnabled(Bool)
    case setMode(String), setModeRx2(String), setRxBandwidth(Int), setRx2Bandwidth(Int)
    case setBwLocked(Bool)
    case recallBand(name: String, defaultHz: UInt32, rx2: Bool)
    case setAgcMode(String)
    case setDsp(DSPFunction, Bool)
    case setCtuneCenterHz(UInt32)
    case setZoomPref(Double)
    case setScrollStepPref(Int)
    case setRound100Pref(Bool)
    /// `secs`: 0 off, -1 hold, -2 live, above 0 seconds (the engine's `peakHoldSecs`).
    case setPeakPref(enabled: Bool, secs: Double)
    case setSmoothingPref(Int)
    case setBandPlanSegmentsPref(Bool)
    case setShowSpotsPref(Bool)
    case setStepPref(ReceiverID, Int)
    /// `SpotStore::activate`: tunes to the spot. The engine guards transmit itself.
    case activateSpot(String)
    case setAfGainDb(Double)
    case setVolume(Double), setVolumeRx2(Double)
    case setMuted(Bool), setMutedRx2(Bool)
    case setBalance(Double)
    case setMonEnabled(Bool), setMonVolume(Double)
    case setAudioOutputDevice(Int)
    case setNbStrength(Double), setLmsStrength(Double), setSquelchThreshold(Double)
    case setApfGainDb(Double), setBinDepth(Double), setNnrMaskFloorDb(Double)
    case setNrMode(Int), setNnrModel(Int)
    case setAgcThreshDb(Double), setAutoAgcThresh(Bool), setAutoAgcMarginDb(Double)
    case addNotch(offsetHz: Double, widthHz: Double)
    case moveNotch(index: Int, offsetHz: Double)
    case setNotchWidth(index: Int, widthHz: Double)
    case removeNotch(index: Int)
}
