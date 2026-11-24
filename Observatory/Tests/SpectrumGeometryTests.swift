import XCTest
@testable import Observatory

final class SpectrumGeometryTests: XCTestCase {
    func testCentreFollowsRitWhenCtuneOff() {
        XCTAssertEqual(SpectrumGeometry.mainCentreHz(rx1Hz: 14_200_000, ritEnabled: true, ritHz: 500,
                                                     ctuneEnabled: false, ctuneCentreHz: 0), 14_200_500)
    }
    func testCentreIgnoresRitWhenOff() {
        XCTAssertEqual(SpectrumGeometry.mainCentreHz(rx1Hz: 14_200_000, ritEnabled: false, ritHz: 500,
                                                     ctuneEnabled: false, ctuneCentreHz: 0), 14_200_000)
    }
    func testCentreIsCtuneCentreWhenOn() {
        XCTAssertEqual(SpectrumGeometry.mainCentreHz(rx1Hz: 14_200_000, ritEnabled: true, ritHz: 500,
                                                     ctuneEnabled: true, ctuneCentreHz: 14_190_000), 14_190_000)
    }
    func testCwMarkerIncludesPitchOffset() {
        let off = SpectrumGeometry.ctunDialOffsetHz(rx1Hz: 7_030_000, ctuneEnabled: true, ctuneCentreHz: 7_028_000)
        XCTAssertEqual(off, 2_000)
        XCTAssertEqual(SpectrumGeometry.mainCarrierHz(centre: 7_028_000, markerOffsetHz: 700, ctunDialOffsetHz: off),
                       7_030_700)
    }
    func testDialOffsetIsZeroWithoutCtune() {
        XCTAssertEqual(SpectrumGeometry.ctunDialOffsetHz(rx1Hz: 7_030_000, ctuneEnabled: false, ctuneCentreHz: 7_028_000), 0)
    }
    func testPassbandUsesEngineOffsets() {
        XCTAssertEqual(SpectrumGeometry.passband(centre: 7_030_000, ctunDialOffsetHz: 0,
                                                 lowOffsetHz: 450, highOffsetHz: 950), 7_030_450...7_030_950)
    }
    func testPassbandMovesWithCtunDialOffset() {
        XCTAssertEqual(SpectrumGeometry.passband(centre: 7_028_000, ctunDialOffsetHz: 2_000,
                                                 lowOffsetHz: -2_700, highOffsetHz: -100), 7_027_300...7_029_900)
    }
    func testPassbandNeverTrapsOnReversedEdges() {
        XCTAssertEqual(SpectrumGeometry.passband(centre: 1_000, ctunDialOffsetHz: 0,
                                                 lowOffsetHz: 50, highOffsetHz: -50), 950...1_050)
    }
    func testSubCarrier() {
        XCTAssertEqual(SpectrumGeometry.subCarrierHz(rx2Hz: 14_200_000, markerOffsetHzRx2: 700), 14_200_700)
    }
    func testOffSpanCue() {
        XCTAssertEqual(SpectrumGeometry.offSpanCue(hz: 99, lowHz: 100, highHz: 200), .left)
        XCTAssertEqual(SpectrumGeometry.offSpanCue(hz: 201, lowHz: 100, highHz: 200), .right)
        XCTAssertNil(SpectrumGeometry.offSpanCue(hz: 100, lowHz: 100, highHz: 200))
        XCTAssertNil(SpectrumGeometry.offSpanCue(hz: 200, lowHz: 100, highHz: 200))
    }
}
