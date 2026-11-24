import simd

/// Mirrors `WaterfallUniforms` in the MSL below; field order and padding must match.
struct WaterfallGPUUniforms {
    var background: SIMD4<Float> = .zero
    var head: UInt32 = 0
    var capacity: UInt32 = 1
    var filled: UInt32 = 0
    var history: UInt32 = 1
}

/// A textured quad over the ring texture. Row k from the top (the newest) lives at ring index
/// `(head + k) % capacity`; rows past `filled` or `history` show the background.
enum WaterfallShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct WaterfallUniforms {
        float4 background;
        uint head;
        uint capacity;
        uint filled;
        uint history;
    };

    struct WaterfallOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex WaterfallOut waterfall_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float(vid & 1u), float(vid >> 1));   // (0,0) (1,0) (0,1) (1,1)
        WaterfallOut out;
        out.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
        out.uv = p;
        return out;
    }

    fragment float4 waterfall_fragment(WaterfallOut in [[stage_in]],
                                       constant WaterfallUniforms &u [[buffer(0)]],
                                       texture2d<float> ring [[texture(0)]]) {
        uint k = min(uint(in.uv.y * float(u.history)), u.history - 1u);
        if (k >= u.filled) { return u.background; }
        uint ty = (u.head + k) % u.capacity;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(ring.sample(s, float2(in.uv.x, (float(ty) + 0.5) / float(u.capacity))).rgb, 1.0);
    }
    """
}
