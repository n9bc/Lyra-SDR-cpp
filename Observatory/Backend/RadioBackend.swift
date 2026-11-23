import Foundation

/// Source of everything the native console renders. Views read only the snapshot
/// and the capabilities; they never reach into an engine.
@MainActor
protocol RadioBackend: AnyObject {
    var capabilities: BackendCapabilities { get }
    var snapshot: RadioSnapshot { get }
}
