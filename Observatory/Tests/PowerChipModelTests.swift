import XCTest
@testable import Observatory

/// The power chip is keyed on the connection capability, not on whether any feature is mocked.
final class PowerChipModelTests: XCTestCase {
    func testMockedConnectionReadsSampleData() {
        for phase: ConnectionPhase in [.streaming, .disconnected, .connecting] {
            let m = PowerChipModel(phase: phase, connectionStatus: .mocked)
            XCTAssertEqual(m.label, "Sample data", "\(phase)")
            XCTAssertEqual(m.style, .warn, "\(phase)")
            XCTAssertEqual(m.help, "Sample data: no radio is connected")
        }
    }

    func testAvailableAndStreamingReadsRunning() {
        let m = PowerChipModel(phase: .streaming, connectionStatus: .available)
        XCTAssertEqual(m.label, "Running")
        XCTAssertEqual(m.style, .armed)
        XCTAssertEqual(m.help, "Radio connection: Running")
    }

    func testAvailableButNotStreamingShowsPhasePlain() {
        let cases: [(ConnectionPhase, String)] = [
            (.disconnected, "Disconnected"), (.discovering, "Discovering"), (.connecting, "Connecting"),
            (.socketOpen, "Socket open"), (.stalled, "Stalled"), (.error("timeout"), "Error"),
        ]
        for (phase, name) in cases {
            let m = PowerChipModel(phase: phase, connectionStatus: .available)
            XCTAssertEqual(m.label, name, "\(phase)")
            XCTAssertEqual(m.style, .plain, "\(phase)")
        }
    }

    func testUnavailableConnectionIsNeverArmed() {
        let m = PowerChipModel(phase: .streaming, connectionStatus: .unavailable("No adapter"))
        XCTAssertEqual(m.style, .plain)
        XCTAssertNotEqual(m.label, "Sample data")
        XCTAssertEqual(m.help, "Radio connection unavailable: No adapter")
        let d = PowerChipModel(phase: .disconnected, connectionStatus: .unavailable("No adapter"))
        XCTAssertEqual(d.label, "Disconnected")
        XCTAssertEqual(d.style, .plain)
    }

    func testOtherMockedFeaturesDoNotTurnTheChipIntoSampleData() {
        let caps = BackendCapabilities(statuses: [.connection: .available], fallback: .mocked)
        XCTAssertTrue(caps.isSampleData)
        let m = PowerChipModel(phase: .streaming, connectionStatus: caps.status(.connection))
        XCTAssertEqual(m.label, "Running")
        XCTAssertEqual(m.style, .armed)
    }
}

final class BackendCapabilitiesTests: XCTestCase {
    func testExplicitStatusesOverrideTheFallback() {
        let caps = BackendCapabilities(statuses: [.connection: .available, .spectrum: .mocked,
                                                  .keyer: .unavailable("No keyer")],
                                       fallback: .available)
        XCTAssertEqual(caps.status(.connection), .available)
        XCTAssertEqual(caps.status(.spectrum), .mocked)
        XCTAssertEqual(caps.status(.keyer), .unavailable("No keyer"))
        XCTAssertEqual(caps.status(.tuning), .available)
    }

    func testOneMockedFeatureMakesItSampleData() {
        let caps = BackendCapabilities(statuses: [.spectrum: .mocked], fallback: .available)
        XCTAssertTrue(caps.isSampleData)
    }

    func testAllAvailableOrUnavailableIsNotSampleData() {
        XCTAssertFalse(BackendCapabilities(fallback: .available).isSampleData)
        let mixed = BackendCapabilities(statuses: [.keyer: .unavailable("No keyer")], fallback: .available)
        XCTAssertFalse(mixed.isSampleData)
    }

    func testMockedFallbackCoveredByExplicitStatusesIsNotSampleData() {
        let all = Dictionary(uniqueKeysWithValues: BackendFeature.allCases.map { ($0, CapabilityStatus.available) })
        XCTAssertFalse(BackendCapabilities(statuses: all, fallback: .mocked).isSampleData)
    }

    func testAllMocked() {
        XCTAssertTrue(BackendCapabilities.allMocked.isSampleData)
        for f in BackendFeature.allCases { XCTAssertEqual(BackendCapabilities.allMocked.status(f), .mocked) }
    }
}
