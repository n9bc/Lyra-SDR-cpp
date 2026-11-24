import XCTest
@testable import Observatory

@MainActor
private final class FakeTerrainSource: TerrainAudioSource {
    var flagCalls: [Bool] = []
    var handler: (@Sendable (UnsafeBufferPointer<Float>, Int) -> Void)?
    func setConsoleAudioStreaming(_ on: Bool) { flagCalls.append(on) }
    func onConsoleAudio(_ handler: (@Sendable (UnsafeBufferPointer<Float>, Int) -> Void)?) { self.handler = handler }

    /// Delivers `count` samples of a 1 kHz tone at 48 kHz.
    func feedTone(count: Int = 6_400) {
        let tone = (0..<count).map { sinf(2 * .pi * 1_000 * Float($0) / 48_000) * 0.5 }
        tone.withUnsafeBufferPointer { handler?($0, 48_000) }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 100
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
}

@MainActor
final class TerrainFeedTests: XCTestCase {
    private func makeFeed(_ source: FakeTerrainSource, clock: Clock = Clock()) -> TerrainFeed {
        TerrainFeed(source: source, clock: { clock.now })
    }

    func testConsoleFlagIgnoresTciChanges() {
        let source = FakeTerrainSource()
        let feed = makeFeed(source)
        feed.isStreaming = true
        feed.start()
        XCTAssertEqual(source.flagCalls, [true])
        // Nothing the console does while expanded, visible and streaming switches the tap off, and a
        // repeated, unchanged condition sends nothing at all (a TCI client's flag is its own).
        feed.isExpanded = true
        feed.isOccluded = false
        feed.isStreaming = true
        XCTAssertEqual(source.flagCalls, [true])
        feed.stop()
    }

    func testFeedStopsWhenCollapsedOccludedOrNotStreaming() {
        let source = FakeTerrainSource()
        let feed = makeFeed(source)
        feed.isStreaming = true
        feed.start()
        feed.isExpanded = false
        XCTAssertEqual(source.flagCalls, [true, false])
        feed.isExpanded = true
        feed.isOccluded = true
        feed.isOccluded = false
        feed.isStreaming = false
        XCTAssertEqual(source.flagCalls, [true, false, true, false, true, false])
        feed.stop()
        XCTAssertEqual(source.flagCalls.last, false)
        XCTAssertNil(source.handler)
    }

    func testNothingIsSentBeforeStreamingAndStopSetsFalse() {
        let source = FakeTerrainSource()
        let feed = makeFeed(source)
        feed.start()
        XCTAssertEqual(source.flagCalls, [])
        feed.stop()
        XCTAssertEqual(source.flagCalls, [false])
    }

    func testFeedIsLiveOnlyWithRecentBlocks() {
        let source = FakeTerrainSource()
        let clock = Clock()
        let feed = makeFeed(source, clock: clock)
        feed.isStreaming = true
        feed.start()
        feed.refreshLiveness()
        XCTAssertFalse(feed.isLive, "no block yet")
        source.feedTone()
        feed.refreshLiveness()
        XCTAssertTrue(feed.isLive)
        clock.advance(0.49)
        feed.refreshLiveness()
        XCTAssertTrue(feed.isLive)
        clock.advance(0.02)
        feed.refreshLiveness()
        XCTAssertFalse(feed.isLive, "older than 0.5 s")
        feed.stop()
    }

    func testOnlyPlainRxCountsAsReceiving() {
        XCTAssertTrue(TerrainFeed.receives(.idle))
        XCTAssertFalse(TerrainFeed.receives(.requested))
        XCTAssertFalse(TerrainFeed.receives(.onAir))
        XCTAssertFalse(TerrainFeed.receives(.releasing))
    }

    func testNotLiveAndBlocksDiscardedWhileTransmitting() async throws {
        let source = FakeTerrainSource()
        let feed = TerrainFeed(source: source)
        feed.isStreaming = true
        feed.start()
        source.feedTone()
        feed.refreshLiveness()
        XCTAssertTrue(feed.isLive)
        feed.isReceiving = false
        XCTAssertFalse(feed.isLive, "TX audio is not received audio")
        // Blocks arriving while keyed are dropped: no row is ever made from them.
        let until = Date().addingTimeInterval(0.6)
        while Date() < until {
            source.feedTone(count: 2_048)
            try await Task.sleep(for: .milliseconds(20))
        }
        feed.refreshLiveness()
        XCTAssertFalse(feed.isLive)
        XCTAssertTrue(feed.grid.isEmpty)
        // Confirmed RX again: rows resume from fresh blocks only.
        feed.isReceiving = true
        feed.refreshLiveness()
        XCTAssertFalse(feed.isLive, "nothing received yet since RX returned")
        let resume = Date().addingTimeInterval(0.6)
        while Date() < resume {
            source.feedTone(count: 2_048)
            try await Task.sleep(for: .milliseconds(20))
        }
        feed.stop()
        XCTAssertFalse(feed.grid.isEmpty)
    }

    func testTerrainLabelAlwaysMain() {
        XCTAssertTrue(AudioTerrainView.detailText(focused: .sub).contains("MAIN"))
        XCTAssertFalse(AudioTerrainView.detailText(focused: .sub).contains("SUB"))
    }

    func testRowsArriveWithinCadence() async throws {
        let source = FakeTerrainSource()
        // The real clock, so blocks stay recent while rows tick.
        let live = TerrainFeed(source: source)
        live.isStreaming = true
        live.start()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            source.feedTone(count: 2_048)
            try await Task.sleep(for: .milliseconds(20))
        }
        live.stop()
        // About 1 s / 133 ms = 7 rows; allow scheduling slack either way.
        XCTAssertGreaterThanOrEqual(live.grid.count, 4)
        XCTAssertLessThanOrEqual(live.grid.count, 9)
        let row = try XCTUnwrap(live.grid.first)
        XCTAssertEqual(row.count, 201)
        // The 1 kHz tone is bin 67 of 201 points over 0-3 kHz.
        let peak = row.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertEqual(peak, 67, accuracy: 2)
    }
}
