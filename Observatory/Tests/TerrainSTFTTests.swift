import XCTest
@testable import Observatory

final class TerrainSTFTTests: XCTestCase {
    private func sine(_ hz: Double, count: Int = 4096, rate: Double = 48_000) -> [Float] {
        (0..<count).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    func testToneLandsInRightPoint() {
        var stft = TerrainSTFT()
        let x = sine(1000)
        let row = x.withUnsafeBufferPointer { stft.row(from: $0) }
        let peak = row.indices.max { row[$0] < row[$1] }!
        XCTAssertTrue(abs(peak - 67) <= 1, "peak at \(peak)")
    }

    func testSilenceIsFloor() {
        var stft = TerrainSTFT()
        let x = [Float](repeating: 0, count: 4096)
        let row = x.withUnsafeBufferPointer { stft.row(from: $0) }
        XCTAssertTrue(row.allSatisfy { $0 <= -100 })
    }

    func testRowLengthIs201() {
        var stft = TerrainSTFT()
        let x = sine(500)
        let row = x.withUnsafeBufferPointer { stft.row(from: $0) }
        XCTAssertEqual(row.count, 201)
    }

    func testHistoryKeeps30NewestFirst() {
        var h = TerrainHistory()
        for i in 0..<35 { h.push([Float(i)]) }
        XCTAssertEqual(h.grid.count, 30)
        XCTAssertEqual(h.grid.first, [34])
        XCTAssertEqual(h.grid.last, [5])
        h.reset()
        XCTAssertTrue(h.grid.isEmpty)
    }

    func testRingReadsLatest() {
        let ring = AudioRing()
        let a = (0..<10_000).map { Float($0) }
        let b = (10_000..<12_000).map { Float($0) }
        a.withUnsafeBufferPointer { ring.append($0) }
        b.withUnsafeBufferPointer { ring.append($0) }
        var out = [Float](repeating: -1, count: 4096)
        let n = out.withUnsafeMutableBufferPointer { ring.read(latest: 4096, into: $0) }
        XCTAssertEqual(n, 4096)
        XCTAssertEqual(out, (7_904..<12_000).map { Float($0) })
        ring.reset()
        let m = out.withUnsafeMutableBufferPointer { ring.read(latest: 4096, into: $0) }
        XCTAssertEqual(m, 0)
    }

    func testRingConcurrentAppendReadIsSafe() {
        let ring = AudioRing()
        let done = expectation(description: "reader")
        let start = Date()
        DispatchQueue.global().async {
            var buf = [Float](repeating: 0, count: 4096)
            while Date().timeIntervalSince(start) < 0.5 {
                let n = buf.withUnsafeMutableBufferPointer { ring.read(latest: 4096, into: $0) }
                XCTAssertTrue((0...4096).contains(n))
            }
            done.fulfill()
        }
        let chunk = [Float](repeating: 0.25, count: 480)
        while Date().timeIntervalSince(start) < 0.5 {
            chunk.withUnsafeBufferPointer { ring.append($0) }
        }
        wait(for: [done], timeout: 5)
    }
}
