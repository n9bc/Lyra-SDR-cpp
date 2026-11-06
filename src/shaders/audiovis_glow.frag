// Lyra audio visualizer glow (neon bloom) — Qt 6 RHI fragment shader.
//
// Draws the HALO only, as a ShaderEffect placed under the AudioVisItem in
// AudioVisCanvas.qml.  `source` is not the picture itself but a glow mask
// (AudioVisGlowItem): the shapes that glow, each filled in its glow colour —
// the mockup's canvas shadowColor, t = level for bars, caps, spokes and
// dots, the FFT line but not its fill or peak trace.  Unlike the
// panadapter's glow.frag there is no brightness threshold: the mask holds
// only those shapes on a TRANSPARENT background.
//
// Like the mockup's canvas shadow, the halo goes UNDER the shapes and never
// brightens them: the item is drawn over this pass with the premultiplied
// "over" rule (base + halo · (1 − base.a)), so an opaque pixel (bar, spoke
// core) comes out unchanged and the palette's amplitude gradient keeps its
// exact colours.
//
// The mask is PREMULTIPLIED alpha and mostly transparent (Background
// opacity 0 lets Lyra's panel colour show through), so the halo blurs all
// four channels — colour AND alpha.  Blurring only .rgb (as glow.frag does
// over the opaque panadapter) would put light into pixels whose alpha stays
// 0, which the premultiplied blend then draws as nothing; the blurred alpha
// makes the halo a real, visible fringe over the panel.
//
// The blur is one pass of a Vogel (golden-angle) disc of kTaps samples with
// gaussian weights, sampled from the mask's mipmaps through a LOD bias so
// the sparse taps don't show as dots on wide radii.  Where mipmaps are not
// available the bias is a no-op and the halo is merely a little grainier.
// Authored once in GLSL; qsb cross-compiles to SPIR-V/MSL/HLSL/GLSL.
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float glowStrength;   // halo gain (0 = none)
    float glowLod;        // mip LOD bias matching the tap spacing
    vec2  glowRadius;     // halo radius in texture coordinates (x, y), the
                          // 3-sigma extent of the gaussian
};

layout(binding = 1) uniform sampler2D source;   // the glow mask

void main() {
    const int   kTaps = 28;
    const float kGolden = 2.39996323;     // golden angle, radians
    vec4  acc  = vec4(0.0);
    float wsum = 0.0;
    for (int i = 0; i < kTaps; ++i) {
        // Equal-area spacing: tap i sits at radius sqrt((i+0.5)/N) of the
        // disc, so each tap stands for the same area and the gaussian
        // weight alone shapes the falloff (sigma = radius / 3).
        float r = sqrt((float(i) + 0.5) / float(kTaps));
        float a = float(i) * kGolden;
        vec2  o = vec2(cos(a), sin(a)) * r * glowRadius;
        float w = exp(-4.5 * r * r);
        acc  += texture(source, qt_TexCoord0 + o, glowLod) * w;
        wsum += w;
    }
    acc /= max(wsum, 0.0001);

    // Halo = the blurred mask scaled by the gain, kept a valid premultiplied
    // colour (alpha <= 1, rgb <= alpha).  The shapes are drawn over it.
    vec4 halo = acc * glowStrength;
    halo.a   = min(halo.a, 1.0);
    halo.rgb = min(halo.rgb, vec3(halo.a));
    fragColor = halo * qt_Opacity;
}
