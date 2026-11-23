import XCTest
@testable import Observatory

final class FilterPresetsTests: XCTestCase {
    func testPresetTablesMatchTheEngine() {
        let ssb = [1500, 1800, 2100, 2400, 2700, 3000, 3600, 4000, 6000, 8000, 10000]
        XCTAssertEqual(FilterPresets.presets(for: .lsb), ssb)
        XCTAssertEqual(FilterPresets.presets(for: .usb), ssb)
        let cw = [50, 100, 150, 250, 400, 500, 750, 1000]
        XCTAssertEqual(FilterPresets.presets(for: .cwl), cw)
        XCTAssertEqual(FilterPresets.presets(for: .cwu), cw)
        XCTAssertEqual(FilterPresets.presets(for: .dsb), [3000, 4000, 5000, 6000, 8000, 10000])
        let am = [3000, 4000, 6000, 8000, 10000, 12000, 16000, 20000]
        XCTAssertEqual(FilterPresets.presets(for: .am), am)
        XCTAssertEqual(FilterPresets.presets(for: .sam), am)
        XCTAssertEqual(FilterPresets.presets(for: .fm), [8000, 10000, 12000, 16000])
        let dig = [1500, 2400, 3000, 3600, 4000, 6000]
        XCTAssertEqual(FilterPresets.presets(for: .digl), dig)
        XCTAssertEqual(FilterPresets.presets(for: .digu), dig)
    }

    func testLabels() {
        XCTAssertEqual(FilterPresets.label(2700), "2.7 k")
        XCTAssertEqual(FilterPresets.label(3000), "3 k")
        XCTAssertEqual(FilterPresets.label(500), "500 Hz")
        XCTAssertEqual(FilterPresets.label(2750), "2.8 k")
        XCTAssertEqual(FilterPresets.label(1500), "1.5 k")
    }

    func testCustomEntryLeadsWhenWidthIsNotAPreset() {
        let e = FilterPresets.entries(mode: .usb, currentHz: 2750)
        XCTAssertEqual(e.first, FilterPresetEntry(hz: 2750, label: "2.8 k (custom)", isCustom: true))
        XCTAssertEqual(e.dropFirst().map(\.hz), FilterPresets.presets(for: .usb))
        XCTAssertEqual(e.count, 12)
    }

    func testChipTitleAndHelpStayShort() {
        let e = FilterPresets.entries(mode: .usb, currentHz: 2750)
        XCTAssertEqual(e[0].chipTitle, "2.8 k*"); XCTAssertEqual(e[0].chipHelp, "Custom width 2.8 kHz")
        XCTAssertEqual(e[1].chipTitle, "1.5 k"); XCTAssertEqual(e[1].chipHelp, "Filter 1.5 k")
        XCTAssertEqual(FilterPresets.entries(mode: .cwu, currentHz: 75)[0].chipHelp, "Custom width 75 Hz")
    }

    func testNoCustomEntryForAPreset() {
        let e = FilterPresets.entries(mode: .usb, currentHz: 2700)
        XCTAssertEqual(e.map(\.hz), FilterPresets.presets(for: .usb))
        XCTAssertTrue(e.allSatisfy { !$0.isCustom })
        XCTAssertEqual(e[4], FilterPresetEntry(hz: 2700, label: "2.7 k", isCustom: false))
    }
}
