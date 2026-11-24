import XCTest
@testable import Observatory

final class BandPlanMappingTests: XCTestCase {
    private func map(_ o: EngineOverlays, _ edit: (inout EngineState.Display) -> Void = { _ in }) -> DisplaySnapshot {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_100_000
        e.display.spanHz = 200_000
        edit(&e.display)
        return LiveSnapshotMapper.snapshot(from: e, phase: .streaming, vfoLocked: false,
                                           now: Date(timeIntervalSinceReferenceDate: 0),
                                           timeZone: TimeZone(identifier: "UTC")!, overlays: o).display
    }

    func testSegmentKindFromLabel() {
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "CW", channel: false), .cw)
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "DIG", channel: false), .digital)
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "CW/DIG", channel: false), .cwDigital)
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "SSB", channel: false), .phone)
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "FM", channel: false), .fm)
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "CH3", channel: true), .channel)
        XCTAssertEqual(LiveSnapshotMapper.bandPlanKind(label: "", channel: false), .mixed)
    }

    func testSegmentsAreMappedWithChannelQsy() {
        let o = EngineOverlays(segments: [
            EngineSegment(lowHz: 7_000_000, highHz: 7_040_000, label: "CW", channel: false, qsyHz: nil),
            EngineSegment(lowHz: 5_332_000, highHz: 5_336_000, label: "CH1", channel: true, qsyHz: 5_330_500),
        ], landmarks: [], spots: [])
        let d = map(o)
        XCTAssertEqual(d.bandPlan.map(\.kind), [.cw, .channel])
        XCTAssertEqual(d.bandPlan.map(\.channelQsyHz), [nil, 5_330_500])
        XCTAssertEqual(d.bandPlan[1].lowHz, 5_332_000)
    }

    func testLandmarksBecomeSpots() {
        let o = EngineOverlays(segments: [], landmarks: [
            EngineLandmark(hz: 7_074_000, label: "FT8", mode: "DIGU", beacon: false),
            EngineLandmark(hz: 14_100_000, label: "NCDXF", mode: "CWU", beacon: true),
        ], spots: [])
        let s = map(o) { $0.bandPlanBeacons = true }.spots
        XCTAssertEqual(s[0].kind, .watering)
        XCTAssertEqual(s[0].label, "FT8"); XCTAssertEqual(s[0].mode, "DIGU")
        XCTAssertEqual(s[0].frequencyHz, 7_074_000)
        XCTAssertEqual(s[1].kind, .beacon)
        XCTAssertEqual(s[1].mode, "CWU")
    }

    func testOwnSpotIsOwnKind() {
        let o = EngineOverlays(segments: [], landmarks: [], spots: [
            EngineSpot(call: "K1ABC", hz: 7_100_000, mine: false, mode: "USB"),
            EngineSpot(call: "VE7XYZ", hz: 7_101_000, mine: true, mode: ""),
        ])
        let s = map(o).spots
        XCTAssertEqual(s.map(\.kind), [.dx, .own])
        XCTAssertEqual(s[0].call, "K1ABC"); XCTAssertEqual(s[0].label, "K1ABC")
        XCTAssertEqual(s[0].mode, "USB"); XCTAssertNil(s[1].mode)
    }

    func testLandmarksWithSameLabelHaveDistinctIDs() {
        let o = EngineOverlays(segments: [], landmarks: [
            EngineLandmark(hz: 7_074_000, label: "FT8", mode: "DIGU", beacon: false),
            EngineLandmark(hz: 14_074_000, label: "FT8", mode: "DIGU", beacon: false),
        ], spots: [])
        XCTAssertEqual(Set(map(o).spots.map(\.id)).count, 2)
    }

    func testOverlaysHiddenWhenFlagsOff() {
        let o = EngineOverlays(
            segments: [EngineSegment(lowHz: 1, highHz: 2, label: "CW", channel: false, qsyHz: nil)],
            landmarks: [EngineLandmark(hz: 7_074_000, label: "FT8", mode: "DIGU", beacon: false),
                        EngineLandmark(hz: 14_100_000, label: "NCDXF", mode: "CWU", beacon: true)],
            spots: [EngineSpot(call: "K1ABC", hz: 7_100_000, mine: false, mode: "USB")])
        let off = map(o) { $0.bandPlanSegments = false; $0.bandPlanLandmarks = false
                           $0.bandPlanBeacons = false; $0.showSpots = false }
        XCTAssertTrue(off.bandPlan.isEmpty); XCTAssertTrue(off.spots.isEmpty)
        let some = map(o) { $0.bandPlanLandmarks = false; $0.bandPlanBeacons = true; $0.showSpots = false }
        XCTAssertEqual(some.spots.map(\.kind), [.beacon])
        XCTAssertEqual(some.bandPlan.count, 1)
    }

    func testLabelClicksSendTheRightCommand() {
        XCTAssertEqual(SpectrumOverlayControls.command(for: Spot(call: "K1ABC", frequencyHz: 7_100_000, kind: .dx)),
                       .activateSpot(call: "K1ABC"))
        XCTAssertEqual(SpectrumOverlayControls.command(for: Spot(call: "FT8", frequencyHz: 7_074_000, kind: .watering, mode: "DIGU")),
                       .tuneLandmark(hz: 7_074_000, mode: "DIGU"))
        XCTAssertEqual(SpectrumOverlayControls.command(for: Spot(call: "NCDXF", frequencyHz: 14_100_000, kind: .beacon)),
                       .tuneLandmark(hz: 14_100_000, mode: ""))
    }
}
