import SwiftUI
import MetalKit

/// Hosts a `LyraMetalRenderer` in an MTKView; shows a muted fallback when Metal is unavailable.
struct LyraMetalView: View {
    let renderer: any LyraMetalRenderer

    init(renderer: any LyraMetalRenderer) {
        self.renderer = renderer
    }

    /// 30 fps in Low Power Mode, otherwise 60.
    nonisolated static func targetFPS(lowPower: Bool) -> Int { lowPower ? 30 : 60 }

    var body: some View {
        if MetalContext.shared != nil {
            MetalHost(renderer: renderer)
        } else {
            Text("Metal unavailable")
                .foregroundStyle(LyraDS.Palette.textMuted)
        }
    }
}

private struct MetalHost: NSViewRepresentable {
    let renderer: any LyraMetalRenderer

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeNSView(context: Context) -> NSView {
        guard let ctx = MetalContext.shared else { return NSView() }
        let view = MTKView()
        view.device = ctx.device
        view.colorPixelFormat = ctx.colorPixelFormat
        if let c = NSColor(LyraDS.Palette.void).usingColorSpace(.sRGB) {
            view.clearColor = MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent),
                                            blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
        }
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = LyraMetalView.targetFPS(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.renderer = renderer
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: any LyraMetalRenderer
        init(renderer: any LyraMetalRenderer) { self.renderer = renderer }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.drawableSizeWillChange(size)
        }

        func draw(in view: MTKView) {
            guard let ctx = MetalContext.shared else { return }
            renderer.draw(in: view, context: ctx)
        }
    }
}
