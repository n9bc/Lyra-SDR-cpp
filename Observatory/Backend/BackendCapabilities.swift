import Foundation

/// How truthfully a backend can serve a feature. The console reads this to decide
/// whether to show the "Sample data" badge.
enum CapabilityStatus: Equatable, Sendable {
    case available
    case mocked
    case unavailable(String)
}

enum BackendFeature: CaseIterable, Sendable {
    case connection, tuning, receiverDSP, audio, frontEnd, transmit, spectrum, waterfall
    case audioTerrain, meters, telemetry, bands, propagation, keyer, recorder, spots
}

struct BackendCapabilities: Equatable, Sendable {
    private let statuses: [BackendFeature: CapabilityStatus]
    private let fallback: CapabilityStatus

    init(statuses: [BackendFeature: CapabilityStatus] = [:], fallback: CapabilityStatus) {
        self.statuses = statuses
        self.fallback = fallback
    }

    func status(_ f: BackendFeature) -> CapabilityStatus { statuses[f] ?? fallback }

    /// True when any feature is served from sample data.
    var isSampleData: Bool {
        BackendFeature.allCases.contains { status($0) == .mocked }
    }

    static let allMocked = BackendCapabilities(fallback: .mocked)
}
