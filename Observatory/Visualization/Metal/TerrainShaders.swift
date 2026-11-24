import simd

/// The terrain's colour map, dark to bright. `LyraDS.Palette.spectrumStops` is not a dark-to-bright
/// ramp (blue, cyan, purple, magenta, yellow: its brightness rises and falls), so the terrain uses
/// an inferno-equivalent 5-stop map (matplotlib inferno at 0, 0.25, 0.5, 0.75 and 1).
enum TerrainPalette {
    nonisolated static let stops: [GradientStop] = [
        stop(0.0, 0x000004),
        stop(0.25, 0x57106E),
        stop(0.5, 0xBC3754),
        stop(0.75, 0xF98E09),
        stop(1.0, 0xFCFFA4),
    ]

    nonisolated private static func stop(_ position: Float, _ hex: UInt32) -> GradientStop {
        GradientStop(position: position,
                     rgba: SIMD4<Float>(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255,
                                        Float(hex & 0xFF) / 255, 1))
    }
}

/// Mirrors MSL `TerrainUniforms` (320 bytes). Field order and padding must match the shader.
struct TerrainGPUUniforms {
    var viewProjection = matrix_identity_float4x4
    /// xyz: unit vector toward the light.
    var light: SIMD4<Float> = .zero
    /// xyz: camera position in world space.
    var eye: SIMD4<Float> = .zero
    /// rgb: fog colour (the void); w: fog strength at the back edge.
    var fog: SIMD4<Float> = .zero
    /// x: surface width, y: surface depth, z: height scale, w: colour-map lift at level 0.
    var surface: SIMD4<Float> = .zero
    /// x: ambient, y: diffuse, z: specular strength, w: specular exponent.
    var shading: SIMD4<Float> = .zero
    /// x: mesh columns, y: mesh rows, z: 1 / texture width, w: 1 / texture height.
    var grid: SIMD4<Float> = .zero
    var stops: (SpectrumGPUStop, SpectrumGPUStop, SpectrumGPUStop, SpectrumGPUStop, SpectrumGPUStop)

    nonisolated static let stopCount = 5

    init(stops palette: [GradientStop]) {
        precondition(palette.count == Self.stopCount, "terrain shader expects \(Self.stopCount) stops")
        let s = palette.map { SpectrumGPUStop(color: $0.rgba, position: $0.position) }
        stops = (s[0], s[1], s[2], s[3], s[4])
    }
}

/// Metal Shading Language for the audio terrain: one continuous mesh whose heights come from a
/// linearly filtered `r32Float` height texture in the vertex shader, lit per pixel from normals
/// taken by central differences of the same texture in the fragment shader. No lines, no
/// outlines and no flat per-quad fills: colour, light and fog all vary per pixel.
enum TerrainShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct TerrainStop {
        float4 color;
        float position;
        float _pad0;
        float _pad1;
        float _pad2;
    };

    struct TerrainUniforms {
        float4x4 viewProjection;
        float4 light;
        float4 eye;
        float4 fog;
        float4 surface;
        float4 shading;
        float4 grid;
        TerrainStop stops[5];
    };

    struct TerrainOut {
        float4 position [[position]];
        float3 world;
        float2 uv;
    };

    constexpr sampler heightSampler(filter::linear, address::clamp_to_edge);

    // Piecewise-linear palette lookup; same algorithm as LyraDS.Palette.sample.
    static float3 palette(constant TerrainUniforms &u, float t) {
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

    // uv.x: 0 (0 Hz, left) ... 1 (3 kHz, right); uv.y: 0 (front, newest) ... 1 (back, oldest).
    static float3 worldPoint(constant TerrainUniforms &u, float2 uv, float h) {
        return float3((uv.x - 0.5) * u.surface.x, h * u.surface.z, (0.5 - uv.y) * u.surface.y);
    }

    vertex TerrainOut terrain_vertex(uint vid [[vertex_id]],
                                     constant TerrainUniforms &u [[buffer(0)]],
                                     texture2d<float> heights [[texture(0)]]) {
        uint cols = uint(u.grid.x);
        uint rows = uint(u.grid.y);
        uint col = vid % cols;
        uint row = min(vid / cols, rows - 1u);
        float2 uv = float2(float(col) / float(cols - 1u), float(row) / float(rows - 1u));
        float h = heights.sample(heightSampler, uv, level(0)).r;
        TerrainOut out;
        out.world = worldPoint(u, uv, h);
        out.position = u.viewProjection * float4(out.world, 1.0);
        out.uv = uv;
        return out;
    }

    fragment float4 terrain_fragment(TerrainOut in [[stage_in]],
                                     constant TerrainUniforms &u [[buffer(0)]],
                                     texture2d<float> heights [[texture(0)]]) {
        float2 uv = in.uv;
        float2 texel = u.grid.zw;
        float h = heights.sample(heightSampler, uv).r;
        float hl = heights.sample(heightSampler, uv - float2(texel.x, 0.0)).r;
        float hr = heights.sample(heightSampler, uv + float2(texel.x, 0.0)).r;
        float hf = heights.sample(heightSampler, uv - float2(0.0, texel.y)).r;   // toward the front
        float hb = heights.sample(heightSampler, uv + float2(0.0, texel.y)).r;   // toward the back

        // World-space slope: x grows with uv.x; z shrinks as uv.y grows (the back is -z).
        float dhdx = (hr - hl) * u.surface.z / (2.0 * texel.x * u.surface.x);
        float dhdz = (hf - hb) * u.surface.z / (2.0 * texel.y * u.surface.y);
        float3 n = normalize(float3(-dhdx, 1.0, -dhdz));

        float3 l = normalize(u.light.xyz);
        float3 v = normalize(u.eye.xyz - in.world);
        float diffuse = max(dot(n, l), 0.0);
        float3 halfway = normalize(l + v);
        // The highlight belongs on crests, not on the flat noise floor.
        float crest = smoothstep(0.25, 0.85, h);
        float spec = pow(max(dot(n, halfway), 0.0), u.shading.w) * u.shading.z * crest;

        float3 base = palette(u, mix(u.surface.w, 1.0, clamp(h, 0.0, 1.0)));
        float3 color = base * (u.shading.x + u.shading.y * diffuse) + float3(spec);

        // Depth fog: the back rows fade toward the void.
        float fogAmount = smoothstep(0.0, 1.0, uv.y) * u.fog.w;
        color = mix(color, u.fog.rgb, fogAmount);
        return float4(color, 1.0);
    }
    """
}
