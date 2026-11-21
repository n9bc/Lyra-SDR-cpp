import XCTest
@testable import Observatory

@MainActor final class MetalContextTests: XCTestCase {
    func testSharedContextExistsOnAppleSilicon() throws {
        XCTAssertNotNil(MetalContext.shared)
    }
    func testLibraryCompilesAndCaches() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let src = "#include <metal_stdlib>\nusing namespace metal;\nkernel void k(uint i [[thread_position_in_grid]]) {}"
        let a = try ctx.library(named: "probe", source: src)
        let b = try ctx.library(named: "probe", source: src)
        XCTAssertTrue(a === b)
        XCTAssertNotNil(a.makeFunction(name: "k"))
    }
    func testBadShaderThrows() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        XCTAssertThrowsError(try ctx.library(named: "bad", source: "not msl"))
    }
    func testTargetFPS() {
        XCTAssertEqual(LyraMetalView.targetFPS(lowPower: true), 30)
        XCTAssertEqual(LyraMetalView.targetFPS(lowPower: false), 60)
    }
}
