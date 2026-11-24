import AppKit
import QuartzCore
import Metal
import MetalKit
import SwiftUI

/// Draws the live waterfall: rows are coloured on the CPU through the engine's palette and
/// written into a ring texture, newest on top, and one textured quad shows the ring.
///
/// Main thread only. The texture is allocated once at the maximum history; the visible history
/// is the drawable height clamped to 64...2048, so resizing never discards rows. A one-deep
/// semaphore keeps the CPU from writing rows the GPU is still reading. Nothing is allocated per
/// frame after `init`.
@MainActor
final class WaterfallRenderer: LyraMetalRenderer {
    nonisolated static let width = SpectrumPump.bins
    nonisolated static let minHistory = 64
    nonisolated static let maxHistory = 2048

    private let bridge: SpectrumBridge
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let ring: MTLTexture
    private let semaphore = DispatchSemaphore(value: 1)
    private let clearColor: MTLClearColor
    private var uniforms = WaterfallGPUUniforms()

    private var builder = WaterfallRowBuilder(bins: SpectrumPump.bins)
    private var autoRange = AutoRange()
    private var lastSerial: UInt64 = 0
    private var lastAutoFeed: TimeInterval = -.infinity
    private var wasAuto = false
    private var seenClearEpoch: UInt64
    private var seenColorEpoch: UInt64?

    private nonisolated(unsafe) let lut: UnsafeMutablePointer<UInt8>          // 768 bytes
    private nonisolated(unsafe) let rowPixels: UnsafeMutablePointer<UInt8>    // width * 4 BGRA
    private var head = 0
    private var filled = 0
    private var history = WaterfallRenderer.minHistory

    nonisolated static func history(forDrawableHeight h: Int) -> Int {
        min(max(h, minHistory), maxHistory)
    }

    init(bridge: SpectrumBridge, context: MetalContext) throws {
        self.bridge = bridge
        self.context = context
        let library = try context.library(named: "waterfall", source: WaterfallShaders.source)
        guard let vf = library.makeFunction(name: "waterfall_vertex") else {
            throw NeonSpectrumRendererError.missingFunction("waterfall_vertex")
        }
        guard let ff = library.makeFunction(name: "waterfall_fragment") else {
            throw NeonSpectrumRendererError.missingFunction("waterfall_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Waterfall"
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = context.colorPixelFormat
        pipeline = try context.device.makeRenderPipelineState(descriptor: desc)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width,
                                                          height: Self.maxHistory, mipmapped: false)
        td.storageMode = .shared
        td.usage = .shaderRead
        guard let tex = context.device.makeTexture(descriptor: td) else {
            throw NeonSpectrumRendererError.textureAllocation
        }
        tex.label = "Waterfall ring"
        ring = tex

        lut = .allocate(capacity: 768)
        lut.initialize(repeating: 0, count: 768)
        rowPixels = .allocate(capacity: Self.width * 4)
        rowPixels.initialize(repeating: 255, count: Self.width * 4)

        clearColor = Self.voidClearColor()
        uniforms.background = SIMD4<Float>(Float(clearColor.red), Float(clearColor.green),
                                           Float(clearColor.blue), 1)
        uniforms.capacity = UInt32(Self.maxHistory)
        seenClearEpoch = bridge.waterfallClearEpoch
        applyColors(bridge.waterfallColors)
        seenColorEpoch = bridge.waterfallColorEpoch
    }

    deinit {
        lut.deallocate()
        rowPixels.deallocate()
    }

    // MARK: - State

    /// Drops the history and pending data (the axis changed, or TX flipped).
    func clear() {
        head = 0
        filled = 0
        builder.reset()
    }

    func setColors(_ colors: WaterfallColors) { applyColors(colors) }

    private func applyColors(_ colors: WaterfallColors) {
        let table = WaterfallColorMap.table(for: colors)
        table.withUnsafeBufferPointer { lut.update(from: $0.baseAddress!, count: 768) }
    }

    /// Colours `row` through the palette and pushes it `count` times, newest on top.
    func emit(_ row: UnsafeBufferPointer<Float>, floor: Float, ceiling: Float, count: Int) {
        guard count > 0, row.count >= Self.width else { return }
        for x in 0..<Self.width {
            let i = WaterfallColorMap.index(db: row[x], floor: floor, ceiling: ceiling) * 3
            let p = rowPixels + x * 4
            p[0] = lut[i + 2]; p[1] = lut[i + 1]; p[2] = lut[i]; p[3] = 255
        }
        for _ in 0..<min(count, Self.maxHistory) {
            head = (head + Self.maxHistory - 1) % Self.maxHistory
            ring.replace(region: MTLRegionMake2D(0, head, Self.width, 1), mipmapLevel: 0,
                         withBytes: rowPixels, bytesPerRow: Self.width * 4)
            filled = min(filled + 1, Self.maxHistory)
        }
    }

    /// One display tick: pull (shared with the spectrum), peak-hold, and push the rows now due.
    func advance(now: TimeInterval) {
        if bridge.waterfallClearEpoch != seenClearEpoch {
            seenClearEpoch = bridge.waterfallClearEpoch
            clear()
            lastSerial = 0
        }
        if bridge.waterfallColorEpoch != seenColorEpoch {
            seenColorEpoch = bridge.waterfallColorEpoch
            applyColors(bridge.waterfallColors)
        }

        let pump = bridge.pump
        pump.tick(now: now, sub: bridge.pullsSub)
        let serial = pump.frameSerial
        let range = bridge.waterfallRange
        if serial != lastSerial, let frame = pump.waterfallRow(bridge.receiver) {
            lastSerial = serial
            builder.ingest(frame, serial: serial)
            if range.auto {
                if !wasAuto { autoRange.reset(); lastAutoFeed = -.infinity }
                if now - lastAutoFeed >= AutoRange.feedInterval {
                    lastAutoFeed = now
                    autoRange.feed(frame)
                }
            }
        }
        wasAuto = range.auto

        guard builder.hasPending else { return }
        let due = builder.rowsDue(now: now, rowsPerSecond: bridge.waterfallRowsPerSecond)
        guard due > 0 else { return }
        let floor = Float(range.auto ? autoRange.floor : range.floor)
        let ceiling = Float(range.auto ? autoRange.ceiling : range.ceiling)
        emit(builder.pendingRow(), floor: floor, ceiling: ceiling, count: due)
        builder.didEmitRow()
    }

    // MARK: - LyraMetalRenderer

    func drawableSizeWillChange(_ size: CGSize) {
        history = Self.history(forDrawableHeight: Int(size.height))
    }

    func draw(in view: MTKView, context: MetalContext) {
        semaphore.wait()
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { semaphore.signal(); return }
        history = Self.history(forDrawableHeight: Int(view.drawableSize.height))
        advance(now: CACurrentMediaTime())

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer() else {
            semaphore.signal()
            return
        }
        commandBuffer.label = "Waterfall"
        let sem = semaphore
        commandBuffer.addCompletedHandler { _ in sem.signal() }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encode(encoder)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encode(_ encoder: MTLRenderCommandEncoder) {
        uniforms.head = UInt32(head)
        uniforms.filled = UInt32(filled)
        uniforms.history = UInt32(history)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaterfallGPUUniforms>.stride, index: 0)
        encoder.setFragmentTexture(ring, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Test support

    /// Renders the current history into a new shared BGRA8 texture of `size` and waits. Tests only.
    func renderOffscreen(size: MTLSize) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: context.colorPixelFormat,
                                                            width: size.width, height: size.height,
                                                            mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .renderTarget
        guard let texture = context.device.makeTexture(descriptor: desc) else {
            throw NeonSpectrumRendererError.textureAllocation
        }
        history = Self.history(forDrawableHeight: size.height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw NeonSpectrumRendererError.commandEncoding
        }
        encode(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private static func voidClearColor() -> MTLClearColor {
        guard let c = NSColor(LyraDS.Palette.void).usingColorSpace(.sRGB) else {
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent),
                             blue: Double(c.blueComponent), alpha: 1)
    }
}
