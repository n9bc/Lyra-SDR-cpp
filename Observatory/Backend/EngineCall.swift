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
}
