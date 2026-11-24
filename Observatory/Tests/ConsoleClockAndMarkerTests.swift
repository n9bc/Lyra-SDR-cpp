import XCTest
@testable import Observatory

final class ConsoleClockAndMarkerTests: XCTestCase {
    func testClockTextFormatsTheGivenDate() {
        let d = Date(timeIntervalSince1970: 1_795_425_449) // 2026-11-23 09:17:29 UTC
        let t = TopBarView.clockText(d, localZone: TimeZone(identifier: "Europe/Oslo")!)
        XCTAssertEqual(t.utc, "09:17:29Z")
        XCTAssertEqual(t.local, "10:17:29 local")
    }

    func testClockTextFollowsTheDateNotTheSnapshot() {
        let d = Date(timeIntervalSince1970: 1_795_425_449 + 3_661)
        let t = TopBarView.clockText(d, localZone: .gmt)
        XCTAssertEqual(t.utc, "10:18:30Z")
        XCTAssertEqual(t.local, "10:18:30 local")
    }

    func testSampleMarkerFollowsTheSpectrumCapability() {
        XCTAssertTrue(DisplayAreaView.showsSampleMarker(.allMocked))
        XCTAssertTrue(DisplayAreaView.showsSampleMarker(
            BackendCapabilities(statuses: [.spectrum: .mocked], fallback: .available)))
        XCTAssertFalse(DisplayAreaView.showsSampleMarker(
            BackendCapabilities(statuses: [.spectrum: .available], fallback: .mocked)))
        XCTAssertFalse(DisplayAreaView.showsSampleMarker(BackendCapabilities(fallback: .available)))
        XCTAssertFalse(DisplayAreaView.showsSampleMarker(
            BackendCapabilities(statuses: [.spectrum: .unavailable("No stream")], fallback: .available)))
    }

    func testEveryDisplayFeatureHasItsOwnSampleMarker() {
        let caps = BackendCapabilities(statuses: [.spectrum: .available, .waterfall: .mocked,
                                                  .audioTerrain: .available], fallback: .available)
        XCTAssertFalse(DisplayAreaView.showsSampleMarker(caps, for: .spectrum))
        XCTAssertTrue(DisplayAreaView.showsSampleMarker(caps, for: .waterfall))
        XCTAssertFalse(DisplayAreaView.showsSampleMarker(caps, for: .audioTerrain))
        let terrain = BackendCapabilities(statuses: [.audioTerrain: .mocked], fallback: .available)
        XCTAssertTrue(DisplayAreaView.showsSampleMarker(terrain, for: .audioTerrain))
        XCTAssertFalse(DisplayAreaView.showsSampleMarker(terrain, for: .waterfall))
        for f in [BackendFeature.spectrum, .waterfall, .audioTerrain] {
            XCTAssertTrue(DisplayAreaView.showsSampleMarker(.allMocked, for: f))
        }
    }

    func testTerrainDetailFollowsFocus() {
        XCTAssertEqual(AudioTerrainView.detailText(focused: .main), "received audio \u{00B7} MAIN \u{00B7} 0\u{2013}3 kHz \u{00B7} last 4 s")
        XCTAssertEqual(AudioTerrainView.detailText(focused: .sub), "received audio \u{00B7} MAIN \u{00B7} 0\u{2013}3 kHz \u{00B7} last 4 s")
    }

    func testVFOReadoutIsDroppedWhenTheSpectrumIsTooShortToShowItWhole() {
        XCTAssertFalse(SpectrumOverlays.showsVFOLabel(height: 59))
        XCTAssertTrue(SpectrumOverlays.showsVFOLabel(height: 76))
        XCTAssertTrue(SpectrumOverlays.showsVFOLabel(height: 218))
    }
}
