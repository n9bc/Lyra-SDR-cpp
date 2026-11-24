import XCTest
@testable import Observatory

final class DisplayToolbarTests: XCTestCase {
    func testWheelLabelMatchesTheMenuOptions() {
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 50), "50 Hz")
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 500), "500 Hz")
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 1000), "1 kHz")
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 2500), "2.5 kHz")
        for hz in [50, 100, 500, 1000] {
            XCTAssertTrue(DisplayToolbarView.wheelOptions.contains(DisplayToolbarView.wheelLabel(hz: hz)), "\(hz)")
        }
    }

    func testPeakOptionsMapToCommands() {
        XCTAssertEqual(DisplayToolbarView.peakSetting(option: "Off"), .off)
        XCTAssertEqual(DisplayToolbarView.peakSetting(option: "Hold"), .hold)
        XCTAssertEqual(DisplayToolbarView.peakSetting(option: "Live"), .live)
        XCTAssertEqual(DisplayToolbarView.peakSetting(option: "0.5 s"), .seconds(0.5))
        XCTAssertEqual(DisplayToolbarView.peakSetting(option: "2 s"), .seconds(2))
        XCTAssertEqual(DisplayToolbarView.peakSetting(option: "5 s"), .seconds(5))
        XCTAssertNil(DisplayToolbarView.peakSetting(option: "nonsense"))
        for option in DisplayToolbarView.peakOptions {
            let setting = DisplayToolbarView.peakSetting(option: option)
            XCTAssertEqual(setting.map(DisplayToolbarView.peakLabel), option)
        }
    }

    func testWheelOptionsMapToHz() {
        XCTAssertEqual(DisplayToolbarView.wheelOptions.map(DisplayToolbarView.wheelHz(option:)), [50, 100, 500, 1000])
        XCTAssertNil(DisplayToolbarView.wheelHz(option: "7 Hz"))
    }

    @MainActor
    func testToolbarSelectionsRenderFromSnapshot() {
        var d = RadioSnapshot.sample.display
        d.wheelStepHz = 100
        d.peakHold = .live
        d.smoothing = 0
        d.exactTuning = true
        d.spotsVisible = false
        d.bandPlanVisible = false
        let c = DisplayToolbarView.chipState(for: d)
        XCTAssertEqual(c.wheel, "100 Hz")
        XCTAssertEqual(c.peak, "Live")
        XCTAssertFalse(c.averaging)
        XCTAssertTrue(c.exact)
        XCTAssertFalse(c.spots)
        XCTAssertFalse(c.bandPlan)
        d.smoothing = 3; d.exactTuning = false; d.spotsVisible = true; d.bandPlanVisible = true
        let on = DisplayToolbarView.chipState(for: d)
        XCTAssertTrue(on.averaging); XCTAssertFalse(on.exact); XCTAssertTrue(on.spots); XCTAssertTrue(on.bandPlan)
    }

    func testToggleCommandsSendTheOppositeOfTheSnapshot() {
        var d = RadioSnapshot.sample.display
        d.smoothing = 4; d.exactTuning = true; d.spotsVisible = true; d.bandPlanVisible = false
        XCTAssertEqual(DisplayToolbarView.toggleCommand(.averaging, display: d), .setAveraging(false))
        XCTAssertEqual(DisplayToolbarView.toggleCommand(.exact, display: d), .setExactTuning(false))
        XCTAssertEqual(DisplayToolbarView.toggleCommand(.spots, display: d), .setSpotsVisible(false))
        XCTAssertEqual(DisplayToolbarView.toggleCommand(.bandPlan, display: d), .setBandPlanVisible(true))
    }

    func testStepChipOptionsAndLabels() {
        XCTAssertEqual(VFOPanelView.stepOptions, [1, 10, 50, 100, 500, 1000, 5000])
    }
}
