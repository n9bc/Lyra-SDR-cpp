import simd

/// One palette stop as laid out for the GPU. Mirrors MSL `SpectrumStop` (32 bytes).
struct SpectrumGPUStop {
    var color: SIMD4<Float>
    var position: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// Mirrors MSL `SpectrumUniforms` (192 bytes). Field order and padding must match the shader.
struct SpectrumUniforms {
    var viewportSize: SIMD2<Float> = .zero
    var columns: UInt32 = 0
    var lineHalfWidthPx: Float = 1.5
    var glowRadiusPx: Float = 8
    var glowSigmaPx: Float = 3
    var pad0: SIMD2<Float> = .zero
    var stops: (SpectrumGPUStop, SpectrumGPUStop, SpectrumGPUStop, SpectrumGPUStop, SpectrumGPUStop)

    static let stopCount = 5

    /// Builds the stop table from the design-system palette; colours are never retyped in MSL.
    init(stops palette: [GradientStop]) {
        precondition(palette.count == Self.stopCount, "spectrum shader expects \(Self.stopCount) stops")
        let s = palette.map { SpectrumGPUStop(color: $0.rgba, position: $0.position) }
        stops = (s[0], s[1], s[2], s[3], s[4])
    }
}

/// Metal Shading Language source for the neon spectrum: a gradient fill under the trace
/// plus an additive glow strip around it. Vertices come from `vertex_id` and a `float`
/// heights buffer (0...1 per column); there is no CPU vertex array.
enum SpectrumShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SpectrumStop {
        float4 color;
        float position;
        float _pad0;
        float _pad1;
        float _pad2;
    };

    struct SpectrumUniforms {
        float2 viewportSize;
        uint columns;
        float lineHalfWidthPx;
        float glowRadiusPx;
        float glowSigmaPx;
        float2 _pad0;
        SpectrumStop stops[5];
    };

    // Piecewise-linear palette lookup; same algorithm as LyraDS.Palette.sample.
    static float3 palette(constant SpectrumUniforms &u, float t) {
        t = clamp(t, 0.0, 1.0);
        if (t <= u.stops[0].position) { return u.stops[0].color.rgb; }
        for (int i = 1; i < 5; ++i) {
            if (t <= u.stops[i].position) {
                float span = u.stops[i].position - u.stops[i - 1].position;
                if (span <= 0.0) { return u.stops[i].color.rgb; }
                float f = (t - u.stops[i - 1].position) / span;
                return mix(u.stops[i - 1].color.rgb, u.stops[i].color.rgb, f);
            }
        }
        return u.stops[4].color.rgb;
    }

    static float columnX(constant SpectrumUniforms &u, uint col) {
        return u.columns > 1 ? float(col) / float(u.columns - 1) : 0.5;
    }

    // ---- Fill: strip of (trace top, baseline) pairs ----

    struct FillOut {
        float4 position [[position]];
        float traceHeight;   // 0...1; linear in x across each strip quad
    };

    vertex FillOut spectrum_fill_vertex(uint vid [[vertex_id]],
                                        constant float *heights [[buffer(0)]],
                                        constant SpectrumUniforms &u [[buffer(1)]]) {
        uint col = min(vid / 2, u.columns - 1);
        float h = clamp(heights[col], 0.0, 1.0);
        float y = (vid % 2 == 0) ? h : 0.0;
        FillOut out;
        out.position = float4(columnX(u, col) * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
        out.traceHeight = h;
        return out;
    }

    fragment float4 spectrum_fill_fragment(FillOut in [[stage_in]],
                                           constant SpectrumUniforms &u [[buffer(0)]]) {
        // Framebuffer y grows downward; convert to 0 (baseline) ... 1 (top).
        float yNorm = 1.0 - in.position.y / u.viewportSize.y;
        float t = in.traceHeight > 0.0 ? clamp(yNorm / in.traceHeight, 0.0, 1.0) : 0.0;
        float alpha = mix(0.05, 0.55, t);
        return float4(palette(u, in.traceHeight), alpha);
    }

    // ---- Glow: strip of +/- glowRadiusPx around the trace ----

    struct GlowOut {
        float4 position [[position]];
        float offsetPx;      // signed vertical pixel distance from the trace
        float traceHeight;
    };

    vertex GlowOut spectrum_glow_vertex(uint vid [[vertex_id]],
                                        constant float *heights [[buffer(0)]],
                                        constant SpectrumUniforms &u [[buffer(1)]]) {
        uint col = min(vid / 2, u.columns - 1);
        float h = clamp(heights[col], 0.0, 1.0);
        float offsetPx = (vid % 2 == 0) ? u.glowRadiusPx : -u.glowRadiusPx;
        float yNdc = h * 2.0 - 1.0 + offsetPx * 2.0 / max(u.viewportSize.y, 1.0);
        GlowOut out;
        out.position = float4(columnX(u, col) * 2.0 - 1.0, yNdc, 0.0, 1.0);
        out.offsetPx = offsetPx;
        out.traceHeight = h;
        return out;
    }

    fragment float4 spectrum_glow_fragment(GlowOut in [[stage_in]],
                                           constant SpectrumUniforms &u [[buffer(0)]]) {
        float d = abs(in.offsetPx);
        float alpha = 1.0;
        if (d > u.lineHalfWidthPx) {
            float e = d - u.lineHalfWidthPx;
            float s = max(u.glowSigmaPx, 1e-3);
            alpha = exp(-(e * e) / (s * s));
        }
        float3 c = palette(u, in.traceHeight);
        // Additive (one, one): premultiply here.
        return float4(c * alpha, alpha);
    }
    """
}
