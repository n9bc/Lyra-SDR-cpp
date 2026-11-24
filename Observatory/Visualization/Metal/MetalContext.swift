import Metal
import MetalKit

/// Shared GPU device, command queue and compiled-shader cache for Observatory's Metal views.
@MainActor
final class MetalContext {
    /// nil when the machine has no Metal device.
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    private var libraries: [String: MTLLibrary] = [:]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
    }

    /// Compiles `source` once per `key` and caches the library. A failed compile throws and is not cached.
    func library(named key: String, source: String) throws -> MTLLibrary {
        if let cached = libraries[key] { return cached }
        let lib = try device.makeLibrary(source: source, options: nil)
        libraries[key] = lib
        return lib
    }
}

/// Implemented by GPU renderers hosted in a `LyraMetalView`.
@MainActor
protocol LyraMetalRenderer: AnyObject {
    /// Called once when the hosting MTKView is made, before its first draw: a renderer that needs
    /// MSAA or a depth buffer sets them here. The default does nothing.
    func configure(_ view: MTKView)
    func draw(in view: MTKView, context: MetalContext)
    func drawableSizeWillChange(_ size: CGSize)
}

extension LyraMetalRenderer {
    func configure(_ view: MTKView) {}
}
