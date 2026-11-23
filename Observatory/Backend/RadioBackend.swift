import Foundation
import Observation

/// Source of everything the native console renders. Views read only the snapshot
/// and the capabilities, and change the radio only through `send(_:)`; they never reach
/// into an engine.
@MainActor
protocol RadioBackend: AnyObject, Observable {
    var capabilities: BackendCapabilities { get }
    var snapshot: RadioSnapshot { get }
    func send(_ command: RadioCommand)
}
