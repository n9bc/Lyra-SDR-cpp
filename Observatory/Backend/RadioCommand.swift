import Foundation

/// A request the console makes of the radio. The backend confirms it by publishing a new
/// snapshot; views never assume the change happened.
enum RadioCommand: Equatable, Sendable {
    case focus(ReceiverID)
    case setSubEnabled(Bool)
    case tune(ReceiverID, deltaHz: Int64)
}
