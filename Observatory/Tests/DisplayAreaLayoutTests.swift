import XCTest
@testable import Observatory

final class DisplayAreaLayoutTests: XCTestCase {
    private func sum(_ l: DisplayAreaLayout) -> CGFloat { l.spectrum + l.waterfall + l.subSpectrum + l.subWaterfall + l.terrain }
    func testReferenceSizeDefault() {
        XCTAssertEqual(DisplayAreaLayout.compute(height: 646),
                       DisplayAreaLayout(spectrum: 218, waterfall: 132, subSpectrum: 0, subWaterfall: 0, terrain: 210))
    }
    func testPartsFillHeightInEveryCombination() {
        for h: CGFloat in [346, 500, 646, 1000] { for layout in DisplayLayout.allCases { for sub in [false, true] { for t in [false, true] {
            let l = DisplayAreaLayout.compute(height: h, layout: layout, subVisible: sub, terrainExpanded: t)
            XCTAssertEqual(sum(l) + DisplayAreaLayout.fixed(subVisible: sub), h, accuracy: 0.5, "\(h) \(layout) \(sub) \(t)")
            for v in [l.spectrum, l.waterfall, l.subSpectrum, l.subWaterfall, l.terrain] { XCTAssertGreaterThanOrEqual(v, 0) }
        } } } }
    }
    func testHiddenPanesAreZero() {
        let so = DisplayAreaLayout.compute(height: 646, layout: .spectrumOnly, subVisible: true)
        XCTAssertEqual(so.waterfall, 0); XCTAssertEqual(so.subWaterfall, 0)
        let wo = DisplayAreaLayout.compute(height: 646, layout: .waterfallOnly, subVisible: true)
        XCTAssertEqual(wo.spectrum, 0); XCTAssertEqual(wo.subSpectrum, 0)
        let noSub = DisplayAreaLayout.compute(height: 646)
        XCTAssertEqual(noSub.subSpectrum, 0); XCTAssertEqual(noSub.subWaterfall, 0)
        XCTAssertEqual(DisplayAreaLayout.compute(height: 646, terrainExpanded: false).terrain, 0)
    }
    func testSubStacksShareEqually() {
        let l = DisplayAreaLayout.compute(height: 646, subVisible: true)
        XCTAssertEqual(l.spectrum, l.subSpectrum, accuracy: 0.001); XCTAssertEqual(l.waterfall, l.subWaterfall, accuracy: 0.001)
    }
    func testShorterThanFixedIsAllZero() {
        XCTAssertEqual(sum(DisplayAreaLayout.compute(height: 40, subVisible: true)), 0)
    }
}
