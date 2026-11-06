// Lyra audio visualizer echo/trails — Qt 6 RHI fragment shader.
//
// One step of the feedback pass in AudioVisCanvas.qml: the new frame drawn
// OVER the previous output, which is first faded by `decay` (Echo / 100).
// Its result is captured by a recursive ShaderEffectSource and fed back as
// `previous` on the next frame, so older frames fade geometrically.
//
// Everything is PREMULTIPLIED alpha: scaling all four channels by `decay`
// fades a trail towards TRANSPARENT (not towards black), so with Background
// opacity 0 the trails dissolve into Lyra's panel colour.
//
// Reaching exactly zero.  The trail texture is half-float where the backend
// can render to one.  `fadeFloor` (1/255) is always set, whatever the real
// format, so a backend that silently falls back to 8-bit still fades out; on
// half-float it only touches the sub-visible tail.  On an 8-bit texture a
// value v that is small enough that v * (1 - decay) < half a step would
// multiply and round straight back to v, and a faint ghost would stick
// forever (at Echo 95 that is every value below 10/255).  Only THERE is one
// 1/255 step taken off instead, so above that level the trail fades
// geometrically too rather than losing a step on every frame (which roughly
// halved the trail at Echo 95).  Per channel: rgb <= alpha is kept because
// each channel's update is monotonic in its input.  Finally anything under
// half an 8-bit step (invisible on screen) is cut to exactly 0, which also
// ends the half-float trail's long sub-visible tail.
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float decay;       // fraction of the previous output kept per frame
    float fadeFloor;   // 8-bit stall step (1/255), always set
};

layout(binding = 1) uniform sampler2D current;    // the visualizer, this frame
layout(binding = 2) uniform sampler2D previous;   // this pass's last output

void main() {
    const float kHalfStep = 0.5 / 255.0;
    vec4 cur  = texture(current, qt_TexCoord0);
    vec4 p    = texture(previous, qt_TexCoord0);
    vec4 stall = vec4(lessThan(p * (1.0 - decay), vec4(kHalfStep)));
    vec4 prev = max(p * decay - stall * fadeFloor, vec4(0.0));
    if (prev.a < kHalfStep) prev = vec4(0.0);
    // Premultiplied "over": the new frame on top, the faded trail under it.
    fragColor = (cur + prev * (1.0 - cur.a)) * qt_Opacity;
}
