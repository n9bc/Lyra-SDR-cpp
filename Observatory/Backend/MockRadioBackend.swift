import Foundation

/// Serves fixed sample data. Every capability is `.mocked`, so the console labels it as such.
@MainActor
final class MockRadioBackend: RadioBackend {
    let capabilities: BackendCapabilities = .allMocked
    private(set) var snapshot: RadioSnapshot

    init(snapshot: RadioSnapshot = .sample) {
        self.snapshot = snapshot
    }
}
