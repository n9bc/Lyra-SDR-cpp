import XCTest
import Metal
@testable import Observatory

@MainActor final class NeonSpectrumRendererTests: XCTestCase {
    func makeRenderer() throws -> NeonSpectrumRenderer {
        try NeonSpectrumRenderer(bridge: .mock(), context: XCTUnwrap(MetalContext.shared))
    }

    func testShaderSourceCompiles() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let lib = try ctx.library(named: "spectrum", source: SpectrumShaders.source)
        for f in ["spectrum_fill_vertex", "spectrum_fill_fragment", "spectrum_glow_vertex", "spectrum_glow_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: f), f)
        }
    }

    func testFullHeightTraceLightsTopRow() throws {
        let tex = try makeRenderer().renderOffscreen(heights: [Float](repeating: 1, count: 64),
                                                     size: MTLSize(width: 128, height: 64, depth: 1))
        let top = pixel(tex, x: 64, y: 1), bottom = pixel(tex, x: 64, y: 62)
        XCTAssertGreaterThan(Int(top.r) + Int(top.g) + Int(top.b), 60)
        XCTAssertGreaterThan(Int(bottom.r) + Int(bottom.g) + Int(bottom.b), 15)
    }

    func testZeroTraceLeavesUpperAreaDark() throws {
        let tex = try makeRenderer().renderOffscreen(heights: [Float](repeating: 0, count: 64),
                                                     size: MTLSize(width: 128, height: 64, depth: 1))
        let p = pixel(tex, x: 64, y: 8)
        XCTAssertLessThan(Int(p.r) + Int(p.g) + Int(p.b), 40)
    }

    func testUniformsLayoutMatchesShader() {
        // MSL: float2 + uint + 3 floats + float2 pad = 32 bytes, then 5 x 32-byte stops.
        XCTAssertEqual(MemoryLayout<SpectrumGPUStop>.stride, 32)
        XCTAssertEqual(MemoryLayout<SpectrumUniforms>.offset(of: \.stops), 32)
        XCTAssertEqual(MemoryLayout<SpectrumUniforms>.stride, 192)
    }

    /// Reads one BGRA8 pixel (Metal y = 0 is the top row) and returns (r, g, b).
    private func pixel(_ tex: MTLTexture, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&bytes, bytesPerRow: tex.width * 4,
                     from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (bytes[2], bytes[1], bytes[0])
    }
}
