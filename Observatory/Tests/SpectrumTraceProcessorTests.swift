import XCTest
@testable import Observatory

final class SpectrumTraceProcessorTests: XCTestCase {
    private func run(_ p: inout SpectrumTraceProcessor, _ value: Float, seconds: Double, dt: Double,
                     smoothing: Int = 0, peak: PeakHoldSetting = .off, decay: Double = 10) {
        let frame = [Float](repeating: value, count: 64)
        let steps = Int((seconds / dt).rounded())
        for _ in 0..<steps {
            frame.withUnsafeBufferPointer {
                p.ingest($0, dt: dt, smoothing: smoothing, peak: peak, decayDbps: decay)
            }
        }
    }

    private func makeProcessor() -> SpectrumTraceProcessor {
        var p = SpectrumTraceProcessor()
        p.resize(bins: 64)
        return p
    }

    func testSmoothingZeroIsRaw() {
        var p = makeProcessor()
        run(&p, -100, seconds: 1.0 / 60, dt: 1.0 / 60)
        run(&p, -40, seconds: 1.0 / 60, dt: 1.0 / 60)
        XCTAssertEqual(p.trace[0], -40)
    }

    func testSmoothingIsTimeBased() {
        var a = makeProcessor(), b = makeProcessor()
        run(&a, -100, seconds: 1.0 / 60, dt: 1.0 / 60, smoothing: 5)
        run(&b, -100, seconds: 1.0 / 30, dt: 1.0 / 30, smoothing: 5)
        run(&a, -40, seconds: 1, dt: 1.0 / 60, smoothing: 5)
        run(&b, -40, seconds: 1, dt: 1.0 / 30, smoothing: 5)
        XCTAssertEqual(a.trace[0], b.trace[0], accuracy: 0.5)
        // Partway through the step the two frame rates still agree, and neither has arrived
        // (smoothing 10 has tau = 0.2 s).
        var c = makeProcessor(), d = makeProcessor()
        run(&c, -100, seconds: 1.0 / 60, dt: 1.0 / 60, smoothing: 10)
        run(&d, -100, seconds: 1.0 / 30, dt: 1.0 / 30, smoothing: 10)
        run(&c, -40, seconds: 0.2, dt: 1.0 / 60, smoothing: 10)
        run(&d, -40, seconds: 0.2, dt: 1.0 / 30, smoothing: 10)
        XCTAssertEqual(c.trace[0], d.trace[0], accuracy: 0.5)
        XCTAssertLessThan(c.trace[0], -55)
        XCTAssertGreaterThan(c.trace[0], -99)
    }

    func testSmoothingTimeConstantMatchesQt() {
        // s = 1: tau_frames = 1.2, tau_s = 0.02 s, so one 0.02 s step moves 1 - 1/e of the way.
        var p = makeProcessor()
        run(&p, -100, seconds: 0.02, dt: 0.02, smoothing: 1)
        run(&p, 0, seconds: 0.02, dt: 0.02, smoothing: 1)
        XCTAssertEqual(p.trace[0], -100 * Float(exp(-1.0)), accuracy: 0.01)
    }

    func testPeakOffIsNil() {
        var p = makeProcessor()
        run(&p, -60, seconds: 0.1, dt: 0.05, peak: .off)
        XCTAssertNil(p.peaks)
    }

    func testPeakHoldSecondsThenDecay() throws {
        var p = makeProcessor()
        run(&p, -40, seconds: 0.125, dt: 0.125, peak: .seconds(2), decay: 10)
        run(&p, -100, seconds: 2, dt: 0.125, peak: .seconds(2), decay: 10)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -40, accuracy: 0.001)
        run(&p, -100, seconds: 1, dt: 0.125, peak: .seconds(2), decay: 10)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -50, accuracy: 0.001)
    }

    func testPeakDecayStopsAtTrace() throws {
        var p = makeProcessor()
        run(&p, -40, seconds: 0.125, dt: 0.125, peak: .seconds(1), decay: 10)
        run(&p, -60, seconds: 10, dt: 0.125, peak: .seconds(1), decay: 10)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -60, accuracy: 0.001)
    }

    func testPeakHoldHoldOnlyRises() throws {
        var p = makeProcessor()
        run(&p, -50, seconds: 0.1, dt: 0.05, peak: .hold)
        run(&p, -70, seconds: 100, dt: 0.5, peak: .hold)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -50)
        run(&p, -30, seconds: 0.05, dt: 0.05, peak: .hold)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -30)
    }

    func testPeakHoldLiveFollowsTrace() throws {
        var p = makeProcessor()
        run(&p, -30, seconds: 0.1, dt: 0.05, peak: .live)
        run(&p, -80, seconds: 0.05, dt: 0.05, peak: .live)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -80)
    }

    func testSwitchingPeakModeReseedsFromTrace() throws {
        var p = makeProcessor()
        run(&p, -30, seconds: 0.1, dt: 0.05, peak: .hold)
        run(&p, -90, seconds: 0.05, dt: 0.05, peak: .off)
        run(&p, -90, seconds: 0.05, dt: 0.05, peak: .hold)
        XCTAssertEqual(try XCTUnwrap(p.peaks)[0], -90)
    }

    func testResetClearsState() {
        var p = makeProcessor()
        run(&p, -30, seconds: 0.1, dt: 0.05, smoothing: 5, peak: .hold)
        p.reset()
        run(&p, -90, seconds: 0.05, dt: 0.05, smoothing: 5, peak: .hold)
        XCTAssertEqual(p.trace[0], -90)
    }

    // MARK: AutoRange (src/autoscale.h)

    private func feed(_ r: inout AutoRange, _ frame: [Float]) {
        frame.withUnsafeBufferPointer { r.feed($0) }
    }

    func testAutoRangeMatchesQt() {
        var r = AutoRange()
        var frame = [Float](repeating: -120, count: 4096)
        frame[100] = -40
        feed(&r, frame)
        XCTAssertEqual(r.floor, -135, accuracy: 1e-9)
        XCTAssertEqual(r.ceiling, -25, accuracy: 1e-9)
    }

    func testAutoRangeMinimumSpan() {
        var r = AutoRange()
        feed(&r, [Float](repeating: -100, count: 4096))
        XCTAssertEqual(r.ceiling - r.floor, 50, accuracy: 1e-9)
    }

    func testAutoRangeSmoothsLaterFeedsAndDecaysPeak() {
        var r = AutoRange()
        var frame = [Float](repeating: -120, count: 4096)
        frame[0] = -40
        feed(&r, frame)
        // Peak gone: the held peak falls 0.25 dB per feed, the applied ceiling moves 10 % of the way.
        feed(&r, [Float](repeating: -120, count: 4096))
        let targetCeil = (-40.0 - 0.25) + 15
        XCTAssertEqual(r.ceiling, -25 + 0.10 * (targetCeil - -25), accuracy: 1e-9)
        XCTAssertEqual(r.floor, -135, accuracy: 1e-9)
    }

    func testAutoRangeIgnoresTinyFrames() {
        var r = AutoRange()
        feed(&r, [-50, -50, -50])
        XCTAssertEqual(r.floor, -130)
        XCTAssertEqual(r.ceiling, -20)
    }

    func testAutoRangeResetReseeds() {
        var r = AutoRange()
        feed(&r, [Float](repeating: -100, count: 4096))
        r.reset()
        feed(&r, [Float](repeating: -60, count: 4096))
        XCTAssertEqual(r.floor, -75, accuracy: 1e-9)
    }
}
