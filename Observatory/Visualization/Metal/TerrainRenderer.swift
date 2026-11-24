import AppKit
import QuartzCore
import Metal
import MetalKit
import simd

enum TerrainRendererError: Error {
    /// Linear filtering of the `r32Float` height texture is what keeps the surface free of steps;
    /// a device without it gets the "Metal unavailable" fallback rather than a stepped terrain.
    case no32BitFloatFiltering
}

/// Draws the audio terrain as one smooth, lit surface: the feed's rows are smoothed across
/// frequency (`TerrainSurface.shapeRow`) and blended over time in dB, upsampled with a monotone
/// cubic onto a 320 x 120 height texture, and
/// mapped through a following dB scale (`TerrainAutoRange`) in the shader, every frame, so a
/// rescale glides rather than jumping at each row. The surface is a static 320 x 140 mesh drawn
/// with 4x MSAA, per-pixel lighting, an inferno-style colour map and depth fog.
///
/// Main thread only. The renderer draws only what its source holds: an empty grid is a flat
/// surface at level 0, and missing (young) rows are flat at the back. The scroll runs only while
/// the feed is live; otherwise it freezes and the MTKView is paused after one frame,
/// until `wake()` (the feed went live again, the grid changed, or the size changed).
@MainActor
final class TerrainRenderer: LyraMetalRenderer {
    nonisolated static let meshColumns = 320
    nonisolated static let meshRows = 140
    nonisolated static let textureWidth = TerrainSurface.width
    nonisolated static let textureHeight = TerrainSurface.height
    nonisolated static let sampleCount = 4
    nonisolated static let depthFormat: MTLPixelFormat = .depth32Float
    /// Points per feed row (`TerrainSTFT`'s default: 0-3 kHz in 15 Hz steps).
    nonisolated static let points = 201

    // Camera and surface: the approved mockup's framing.
    nonisolated static let eye = SIMD3<Float>(0, 1.35, 2.35)
    nonisolated static let target = SIMD3<Float>(0, 0.05, -0.15)
    nonisolated static let fovY: Float = 0.62
    nonisolated static let surfaceWidth: Float = 2.6
    nonisolated static let surfaceDepth: Float = 2.0
    nonisolated static let heightScale: Float = 0.55

    // Fit to the pane (points). The front (newest) edge spans the frequency labels' axis, from
    // `axisInsetPt` to width - `axisInsetPt`, and sits `labelBandPt` above the bottom, just over
    // the label row; the back crest (full height at the back edge) reaches `topMarginPt` from the
    // top. The mockup's camera direction and perspective are kept; only the scale and offset of
    // the image change with the pane's size, so the labels read true at any aspect.
    nonisolated static let axisInsetPt: CGFloat = 24
    nonisolated static let labelBandPt: CGFloat = 18
    nonisolated static let topMarginPt: CGFloat = 6

    /// What the renderer draws: the live feed, or a fixed sample grid.
    enum Source {
        case feed(TerrainFeed)
        case sample([[Float]])
    }

    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let indices: MTLBuffer
    private let indexCount: Int
    private let heightTexture: MTLTexture
    private let semaphore = DispatchSemaphore(value: 1)
    private let clearColor: MTLClearColor
    private var uniforms = TerrainGPUUniforms(stops: TerrainPalette.stops)
    private var framedSize: CGSize = .zero

    private var source: Source = .sample([])
    private weak var view: MTKView?

    private var range = TerrainAutoRange()
    private var clock = TerrainScrollClock()
    private var lastNewest: [Float]?
    private var lastCount = -1
    private var lastFrame: TimeInterval?
    /// The dB the height texture is measured from: the scale's floor when the rows were built.
    private var referenceDb: Float = -100
    /// The height rows (dB above `referenceDb`) upsampled across frequency, newest first, `TerrainHistory.rows` of them.
    private var columns: [[Float]] = []
    private var heights: [Float]

    init(context: MetalContext) throws {
        self.context = context
        let device = context.device
        guard device.supports32BitFloatFiltering else { throw TerrainRendererError.no32BitFloatFiltering }

        let library = try context.library(named: "terrain", source: TerrainShaders.source)
        guard let vf = library.makeFunction(name: "terrain_vertex") else {
            throw NeonSpectrumRendererError.missingFunction("terrain_vertex")
        }
        guard let ff = library.makeFunction(name: "terrain_fragment") else {
            throw NeonSpectrumRendererError.missingFunction("terrain_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Audio terrain"
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = context.colorPixelFormat
        desc.depthAttachmentPixelFormat = Self.depthFormat
        desc.rasterSampleCount = Self.sampleCount
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw NeonSpectrumRendererError.commandEncoding
        }
        depthState = ds

        let mesh = Self.meshIndices(columns: Self.meshColumns, rows: Self.meshRows)
        guard let ib = mesh.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count,
                                                                 options: .storageModeShared) }) else {
            throw NeonSpectrumRendererError.bufferAllocation
        }
        ib.label = "Terrain mesh indices"
        indices = ib
        indexCount = mesh.count

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: Self.textureWidth,
                                                          height: Self.textureHeight, mipmapped: false)
        td.storageMode = .shared
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else {
            throw NeonSpectrumRendererError.textureAllocation
        }
        tex.label = "Terrain heights"
        heightTexture = tex
        heights = [Float](repeating: 0, count: Self.textureWidth * Self.textureHeight)

        clearColor = Self.voidClearColor()
        uniforms.light = SIMD4<Float>(simd_normalize(SIMD3<Float>(-0.45, 0.8, 0.4)), 0)
        uniforms.eye = SIMD4<Float>(Self.eye, 1)
        uniforms.fog = SIMD4<Float>(Float(clearColor.red), Float(clearColor.green), Float(clearColor.blue), 0.75)
        uniforms.surface = SIMD4<Float>(Self.surfaceWidth, Self.surfaceDepth, Self.heightScale, 0.06)
        uniforms.shading = SIMD4<Float>(0.35, 0.85, 0.35, 24)
        uniforms.grid = SIMD4<Float>(Float(Self.meshColumns), Float(Self.meshRows),
                                     1 / Float(Self.textureWidth), 1 / Float(Self.textureHeight))
    }

    // MARK: - Source and pausing

    /// Switches what is drawn. A sample grid's scale is settled at once (it never changes); the
    /// live feed starts from the scale's start values, not from whatever the last source left.
    func setSource(_ newSource: Source) {
        source = newSource
        lastNewest = nil
        lastCount = -1
        lastFrame = nil
        range = TerrainAutoRange()
        if case .sample(let grid) = newSource {
            settleSampleRange(grid)
        }
        wake()
    }

    /// The Smooth control's shaping. A change rebuilds the rows on the next frame; a sample grid's
    /// scale is settled again for the new shape.
    var shaping: TerrainShaping = .standard {
        didSet {
            guard shaping != oldValue else { return }
            // Forces the next ingest to rebuild the rows. `lastNewest` stays, so rows that
            // arrive while the slider moves still advance the scroll clock.
            lastCount = -1
            if case .sample(let grid) = source {
                range = TerrainAutoRange()
                settleSampleRange(grid)
            }
            wake()
        }
    }

    private func settleSampleRange(_ grid: [[Float]]) {
        for _ in 0..<20 {
            range.retarget(drawnGrid: grid,
                           referenceDb: min(range.floorDb, range.targetFloorDb) - Self.referenceMarginDb,
                           shaping: shaping)
            range.advance(dt: 1)
        }
    }

    /// The scale the next frame maps through. Tests only.
    var autoRange: TerrainAutoRange { range }

    /// Resumes drawing; `draw` pauses again after one frame while the source is not live.
    func wake() {
        view?.isPaused = false
    }

    private var current: (grid: [[Float]], live: Bool) {
        switch source {
        case .feed(let feed): (feed.grid, feed.isLive)
        case .sample(let grid): (grid, false)
        }
    }

    // MARK: - Pure helpers

    /// `levels` (newest first) as exactly `rows` rows of `points`: missing rows are flat 0 at the
    /// back, and each row is cut or zero-padded to `points`.
    nonisolated static func padded(_ levels: [[Float]], rows: Int, points: Int) -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(rows)
        for row in levels.prefix(rows) {
            if row.count == points { out.append(row); continue }
            var r = Array(row.prefix(points))
            r.append(contentsOf: [Float](repeating: 0, count: points - r.count))
            out.append(r)
        }
        while out.count < rows { out.append([Float](repeating: 0, count: points)) }
        return out
    }

    /// Two triangles per grid cell over a `columns` x `rows` vertex grid, 32-bit indices.
    nonisolated static func meshIndices(columns: Int, rows: Int) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let a = UInt32(r * columns + c), b = a + 1
                let d = UInt32((r + 1) * columns + c), e = d + 1
                out.append(contentsOf: [a, d, b, b, d, e])
            }
        }
        return out
    }

    /// Right-handed perspective onto Metal's 0...1 depth range.
    nonisolated static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovY / 2)
        let xs = ys / max(aspect, 1e-3)
        let zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4<Float>(xs, 0, 0, 0), SIMD4<Float>(0, ys, 0, 0),
                                       SIMD4<Float>(0, 0, zs, -1), SIMD4<Float>(0, 0, zs * near, 0)))
    }

    nonisolated static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4<Float>(s.x, u.x, -f.x, 0), SIMD4<Float>(s.y, u.y, -f.y, 0),
                                       SIMD4<Float>(s.z, u.z, -f.z, 0),
                                       SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// How far below the floor the height texture's reference sits: one second of fall.
    nonisolated static let referenceMarginDb = TerrainAutoRange.fallDbPerSecond

    /// The shader's level mapping for `range`, relative to a height texture measured from
    /// `referenceDb`.
    nonisolated static func rangeUniform(_ range: TerrainAutoRange, referenceDb: Float) -> SIMD4<Float> {
        SIMD4<Float>(range.floorDb - referenceDb, range.ceilingDb - referenceDb, TerrainAutoRange.kneeLevel, 0)
    }

    /// The view-projection for a pane of `viewSize` points: the mockup's camera, then a clip-space
    /// scale and shift that puts the front edge on the label axis and the back crest under the top.
    nonisolated static func framing(viewSize: CGSize) -> simd_float4x4 {
        let w = Float(max(viewSize.width, 1)), h = Float(max(viewSize.height, 1))
        let base = perspective(fovY: fovY, aspect: w / h, near: 0.1, far: 20)
            * lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
        func ndc(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let c = base * SIMD4<Float>(p, 1)
            return SIMD2<Float>(c.x, c.y) / c.w
        }
        let front = ndc(SIMD3<Float>(surfaceWidth / 2, 0, surfaceDepth / 2))
        let crest = ndc(SIMD3<Float>(0, heightScale, -surfaceDepth / 2))
        let wantX = 1 - 2 * Float(axisInsetPt) / w
        let wantFront = -1 + 2 * Float(labelBandPt) / h
        let wantCrest = 1 - 2 * Float(topMarginPt) / h
        let sx = wantX / front.x
        let sy = (wantCrest - wantFront) / (crest.y - front.y)
        let dy = wantFront - sy * front.y
        // Clip space: x' = sx x, y' = sy y + dy w (a lens shift), z and w unchanged.
        let fit = simd_float4x4(columns: (SIMD4<Float>(sx, 0, 0, 0), SIMD4<Float>(0, sy, 0, 0),
                                          SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, dy, 0, 1)))
        return fit * base
    }

    // MARK: - Frame preparation

    /// How many rows landed between `previousNewest` and `grid` (newest first): where the old
    /// newest row now sits, or 1 when it cannot be found; 0 when the newest row is unchanged or
    /// there was nothing before.
    nonisolated static func arrivedRows(_ grid: [[Float]], previousNewest: [Float]?) -> Int {
        guard let previousNewest, let newest = grid.first, newest != previousNewest else { return 0 }
        return grid.indices.dropFirst().first { grid[$0] == previousNewest } ?? 1
    }

    /// Takes a new grid into the scale's targets and the cached rows. Only runs when the grid
    /// changed. The scale itself moves per frame, in `prepare`.
    private func ingest(_ grid: [[Float]], now: TimeInterval) {
        let newest = grid.first
        guard grid.count != lastCount || newest != lastNewest else { return }
        let arrived = Self.arrivedRows(grid, previousNewest: lastNewest)
        lastCount = grid.count
        lastNewest = newest

        if case .feed = source {
            // The peak is read from the heights as drawn, measured from the same reference the rows
            // below are built from (it moves only when the floor does, by a few dB at most).
            range.retarget(drawnGrid: grid,
                           referenceDb: min(range.floorDb, range.targetFloorDb) - Self.referenceMarginDb,
                           shaping: shaping)
        }
        // Measured from below both where the floor is and where it is heading (with a second of
        // fall to spare), so nothing the scale shows before the next row is clamped away and the
        // flat padding rows stay at level 0.
        referenceDb = min(range.floorDb, range.targetFloorDb) - Self.referenceMarginDb
        let heights = TerrainSurface.heightRows(grid: grid, referenceDb: referenceDb, shaping: shaping)
        columns = Self.padded(heights, rows: TerrainHistory.rows, points: Self.points)
            .map { TerrainSurface.upsampleRow($0, width: Self.textureWidth) }
        if arrived > 0 { clock.rowsArrived(arrived, at: now) }
    }

    private func prepare(now: TimeInterval, viewSize: CGSize) -> Bool {
        let (grid, live) = current
        ingest(grid, now: now)
        // The scale glides only while live (a dim, paused terrain holds still). A long gap (the
        // view was paused) is capped at one row period, so waking never jumps the scale.
        let dt = lastFrame.map { min(max(now - $0, 0), TerrainScrollClock.nominalPeriod) } ?? 0
        lastFrame = now
        if live { range.advance(dt: dt) }
        uniforms.range = Self.rangeUniform(range, referenceDb: referenceDb)
        let lag = clock.advance(now: now, live: live)
        heights.withUnsafeMutableBufferPointer {
            TerrainSurface.upsampleTime(columns: columns, lag: lag, height: Self.textureHeight, into: $0)
        }
        heights.withUnsafeBytes {
            heightTexture.replace(region: MTLRegionMake2D(0, 0, Self.textureWidth, Self.textureHeight),
                                  mipmapLevel: 0, withBytes: $0.baseAddress!,
                                  bytesPerRow: Self.textureWidth * MemoryLayout<Float>.stride)
        }
        if viewSize != framedSize {
            framedSize = viewSize
            uniforms.viewProjection = Self.framing(viewSize: viewSize)
        }
        return live
    }

    private func encode(_ encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TerrainGPUUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerrainGPUUniforms>.stride, index: 0)
        encoder.setVertexTexture(heightTexture, index: 0)
        encoder.setFragmentTexture(heightTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
    }

    // MARK: - LyraMetalRenderer

    func configure(_ view: MTKView) {
        view.sampleCount = Self.sampleCount
        view.depthStencilPixelFormat = Self.depthFormat
        self.view = view
    }

    func drawableSizeWillChange(_ size: CGSize) {
        // A paused view does not redraw on its own; one frame at the new size, then it pauses again.
        wake()
    }

    func draw(in view: MTKView, context: MetalContext) {
        semaphore.wait()
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { semaphore.signal(); return }
        // Framed in points, the unit the SwiftUI label row is laid out in.
        let points = view.bounds.size.width > 0 && view.bounds.size.height > 0 ? view.bounds.size : size
        let live = prepare(now: CACurrentMediaTime(), viewSize: points)

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer() else {
            semaphore.signal()
            return
        }
        commandBuffer.label = "Audio terrain"
        let sem = semaphore
        commandBuffer.addCompletedHandler { _ in sem.signal() }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encode(encoder)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Not live: the scroll is frozen and nothing changes until `wake()`.
        if !live { view.isPaused = true }
    }

    // MARK: - Test support

    /// Renders `grid` (newest first, dBFS; its scale settled) through the same MSAA + depth path
    /// into a new shared BGRA8 texture of `size` and waits. Tests only.
    func renderOffscreen(grid: [[Float]], size: MTLSize) throws -> MTLTexture {
        setSource(.sample(grid))
        let device = context.device
        func texture(_ format: MTLPixelFormat, multisample: Bool, shared: Bool) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width,
                                                             height: size.height, mipmapped: false)
            if multisample { d.textureType = .type2DMultisample; d.sampleCount = Self.sampleCount }
            d.storageMode = shared ? .shared : .private
            d.usage = .renderTarget
            guard let t = device.makeTexture(descriptor: d) else { throw NeonSpectrumRendererError.textureAllocation }
            return t
        }
        let msaa = try texture(context.colorPixelFormat, multisample: true, shared: false)
        let resolved = try texture(context.colorPixelFormat, multisample: false, shared: true)
        let depth = try texture(Self.depthFormat, multisample: true, shared: false)

        _ = prepare(now: CACurrentMediaTime(), viewSize: CGSize(width: size.width, height: size.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw NeonSpectrumRendererError.commandEncoding
        }
        encode(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return resolved
    }

    private static func voidClearColor() -> MTLClearColor {
        guard let c = NSColor(LyraDS.Palette.void).usingColorSpace(.sRGB) else {
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent),
                             blue: Double(c.blueComponent), alpha: 1)
    }
}
