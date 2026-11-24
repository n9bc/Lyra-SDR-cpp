import AppKit
import QuartzCore
import Metal
import MetalKit
import SwiftUI

enum NeonSpectrumRendererError: Error {
    case missingFunction(String)
    case bufferAllocation
    case textureAllocation
    case commandEncoding
}

/// Draws the live spectrum as a gradient fill plus an additive neon glow line.
///
/// Main-thread only. Three heights buffers are rotated and gated by a semaphore so the CPU
/// never overwrites a buffer the GPU is still reading; the completion handler (the only
/// off-main code) captures nothing but the semaphore.
@MainActor
final class NeonSpectrumRenderer: LyraMetalRenderer {
    static let maxColumns = 2048
    private static let inFlight = 3

    private let bridge: SpectrumBridge
    private let context: MetalContext
    private let fillPipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    private var processor = SpectrumFrameProcessor()
    private var trace = SpectrumTraceProcessor()
    private var autoRange = AutoRange()
    private var lastSerial: UInt64 = 0
    private var lastIngest: TimeInterval?
    private var lastAutoFeed: TimeInterval = -.infinity
    private var wasAuto = false
    private let heightBuffers: [MTLBuffer]
    private let peakBuffers: [MTLBuffer]
    private var bufferIndex = 0
    private let semaphore = DispatchSemaphore(value: NeonSpectrumRenderer.inFlight)
    private var uniforms: SpectrumUniforms
    private let clearColor: MTLClearColor

    init(bridge: SpectrumBridge, context: MetalContext) throws {
        self.bridge = bridge
        self.context = context
        let device = context.device
        let library = try context.library(named: "spectrum", source: SpectrumShaders.source)

        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw NeonSpectrumRendererError.missingFunction(name)
            }
            return f
        }

        let fill = MTLRenderPipelineDescriptor()
        fill.label = "Spectrum fill"
        fill.vertexFunction = try function("spectrum_fill_vertex")
        fill.fragmentFunction = try function("spectrum_fill_fragment")
        if let att = fill.colorAttachments[0] {
            att.pixelFormat = context.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        fillPipeline = try device.makeRenderPipelineState(descriptor: fill)

        let glow = MTLRenderPipelineDescriptor()
        glow.label = "Spectrum glow"
        glow.vertexFunction = try function("spectrum_glow_vertex")
        glow.fragmentFunction = try function("spectrum_glow_fragment")
        if let att = glow.colorAttachments[0] {
            att.pixelFormat = context.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
        }
        glowPipeline = try device.makeRenderPipelineState(descriptor: glow)

        var buffers: [MTLBuffer] = []
        for i in 0..<Self.inFlight {
            guard let b = device.makeBuffer(length: Self.maxColumns * MemoryLayout<Float>.stride,
                                            options: .storageModeShared) else {
                throw NeonSpectrumRendererError.bufferAllocation
            }
            b.label = "Spectrum heights \(i)"
            buffers.append(b)
        }
        heightBuffers = buffers

        var peaks: [MTLBuffer] = []
        for i in 0..<Self.inFlight {
            guard let b = device.makeBuffer(length: Self.maxColumns * MemoryLayout<Float>.stride,
                                            options: .storageModeShared) else {
                throw NeonSpectrumRendererError.bufferAllocation
            }
            b.label = "Spectrum peaks \(i)"
            peaks.append(b)
        }
        peakBuffers = peaks
        trace.resize(bins: SpectrumPump.bins)

        uniforms = SpectrumUniforms(stops: LyraDS.Palette.spectrumStops)
        clearColor = Self.voidClearColor()
    }

    // MARK: - LyraMetalRenderer

    func drawableSizeWillChange(_ size: CGSize) {
        processor.resize(columns: SpectrumFrameProcessor.columnCount(forDrawableWidth: Int(size.width)))
    }

    func draw(in view: MTKView, context: MetalContext) {
        semaphore.wait()

        // drawableSizeWillChange is not guaranteed before the first draw, so size here too.
        let width = Int(view.drawableSize.width)
        guard width > 0, view.drawableSize.height > 0 else { semaphore.signal(); return }
        processor.resize(columns: SpectrumFrameProcessor.columnCount(forDrawableWidth: width))
        let columns = min(processor.heights.count, Self.maxColumns)
        guard columns > 1 else { semaphore.signal(); return }

        // One pump pull per display tick; the pump skips it if the other stack already pulled.
        let now = CACurrentMediaTime()
        let pump = bridge.pump
        pump.tick(now: now, sub: bridge.pullsSub)

        let serial = pump.spectrumSerial(bridge.receiver)
        if serial != lastSerial, let frame = pump.spectrum(bridge.receiver) {
            lastSerial = serial
            let dt = lastIngest.map { min(max(now - $0, 0), 1) } ?? 1.0 / 60
            lastIngest = now
            trace.ingest(frame, dt: dt, smoothing: bridge.smoothing, peak: bridge.peakHold,
                         decayDbps: bridge.peakDecayDbps)
            if bridge.dbRange.auto {
                if !wasAuto { autoRange.reset(); lastAutoFeed = -.infinity }
                if now - lastAutoFeed >= AutoRange.feedInterval {
                    lastAutoFeed = now
                    autoRange.feed(frame)
                    bridge.publishAutoRange(floor: autoRange.floor, ceiling: autoRange.ceiling)
                }
            }
        }
        wasAuto = bridge.dbRange.auto
        // No new frame: keep showing the last trace.

        let floor = Float(bridge.dbFloor), ceiling = Float(bridge.dbCeiling)
        trace.trace.withUnsafeBufferPointer { processor.ingest($0, floor: floor, ceiling: ceiling) }
        let peakColumns: Bool
        if let peaks = trace.peaks {
            peaks.withUnsafeBufferPointer { processor.ingestPeaks($0, floor: floor, ceiling: ceiling) }
            peakColumns = true
        } else {
            peakColumns = false
        }

        let buffer = heightBuffers[bufferIndex]
        processor.heights.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                buffer.contents().copyMemory(from: base, byteCount: columns * MemoryLayout<Float>.stride)
            }
        }
        let peakBuffer = peakBuffers[bufferIndex]
        if peakColumns {
            processor.peakHeights.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    peakBuffer.contents().copyMemory(from: base, byteCount: columns * MemoryLayout<Float>.stride)
                }
            }
        }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer() else {
            semaphore.signal()
            return
        }
        commandBuffer.label = "Neon spectrum"
        let sem = semaphore
        commandBuffer.addCompletedHandler { _ in sem.signal() }

        let viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encode(encoder, heights: buffer, columns: columns, viewport: viewport,
                   peaks: peakColumns ? peakBuffer : nil)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()   // completion handler signals the semaphore
        bufferIndex = (bufferIndex + 1) % Self.inFlight
    }

    // MARK: - Shared encoding

    private func encode(_ encoder: MTLRenderCommandEncoder, heights: MTLBuffer, columns: Int,
                        viewport: SIMD2<Float>, peaks: MTLBuffer? = nil) {
        uniforms.columns = UInt32(columns)
        uniforms.viewportSize = viewport
        var u = uniforms
        let size = MemoryLayout<SpectrumUniforms>.stride
        let vertexCount = columns * 2

        encoder.setRenderPipelineState(fillPipeline)
        encoder.setVertexBuffer(heights, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: size, index: 1)
        encoder.setFragmentBytes(&u, length: size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)

        encoder.setRenderPipelineState(glowPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)

        // Peak hold: the glow strip with a hairline core and almost no halo.
        if let peaks {
            var thin = u
            thin.lineHalfWidthPx = 0.75
            thin.glowRadiusPx = 2
            thin.glowSigmaPx = 0.6
            encoder.setVertexBuffer(peaks, offset: 0, index: 0)
            encoder.setVertexBytes(&thin, length: size, index: 1)
            encoder.setFragmentBytes(&thin, length: size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
        }
    }

    // MARK: - Test support

    /// Renders `heights` (0...1 per column) with the same pipelines and uniforms into a new
    /// shared BGRA8 texture cleared to the void colour, and waits for the GPU. Tests only.
    func renderOffscreen(heights: [Float], size: MTLSize) throws -> MTLTexture {
        let ctx = context
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.colorPixelFormat,
                                                            width: size.width, height: size.height,
                                                            mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .renderTarget
        guard let texture = ctx.device.makeTexture(descriptor: desc) else {
            throw NeonSpectrumRendererError.textureAllocation
        }
        let columns = min(heights.count, Self.maxColumns)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor

        guard let commandBuffer = ctx.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw NeonSpectrumRendererError.commandEncoding
        }
        if columns > 1 {
            let buffer = try heights.withUnsafeBytes { raw -> MTLBuffer in
                guard let base = raw.baseAddress,
                      let b = ctx.device.makeBuffer(bytes: base, length: columns * MemoryLayout<Float>.stride,
                                                    options: .storageModeShared) else {
                    throw NeonSpectrumRendererError.bufferAllocation
                }
                return b
            }
            encode(encoder, heights: buffer, columns: columns,
                   viewport: SIMD2<Float>(Float(size.width), Float(size.height)))
        }
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
                             blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}
