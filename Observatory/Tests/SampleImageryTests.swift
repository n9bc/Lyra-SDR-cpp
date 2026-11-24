import XCTest
import CoreGraphics
@testable import Observatory

final class SampleImageryTests: XCTestCase {
    func testTerrainGridDeterministicAndFinite() {
        let a = SampleImagery.terrainGrid()
        XCTAssertEqual(a, SampleImagery.terrainGrid())
        XCTAssertEqual(a.count, 30)
        for row in a {
            XCTAssertEqual(row.count, 201)
            XCTAssertTrue(row.allSatisfy { $0.isFinite && $0 <= 0 })
        }
    }

    func testWaterfallSize() {
        let axis = FrequencyAxis(lowHz: 7_060_000, highHz: 7_200_000, width: 940)
        let img = SampleImagery.waterfall(width: 940, height: 132, axis: axis, signals: [7_128_500])
        XCTAssertEqual(img.width, 940)
        XCTAssertEqual(img.height, 132)
    }
}

final class SampleImageryTraceTests: XCTestCase {
    private func pixel(_ img: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = img.dataProvider!.data! as Data
        let o = y * img.bytesPerRow + x * 4
        return Array(data[o..<o + 3])
    }

    func testAudioTraceIsNarrow() {
        let axis = FrequencyAxis(lowHz: 0, highHz: 3000, width: 600)
        let img = SampleImagery.waterfall(width: 600, height: 60, axis: axis, signals: [1500], traceWidthHz: 70)
        let y = 4
        let centre = pixel(img, x: 300, y: y)
        for x in [100, 200, 400, 500] { XCTAssertNotEqual(pixel(img, x: x, y: y), centre) }
    }
}
