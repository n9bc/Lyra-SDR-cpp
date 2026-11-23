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
}
