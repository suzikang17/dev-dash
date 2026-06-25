#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// An animated "aurora" gradient. SwiftUI calls this once per pixel via the
// .colorEffect() modifier. We get the pixel's on-screen position and its
// current color, and we return a new color. For text, `color.a` is the glyph
// coverage (1 inside a letter, 0 outside), so multiplying our gradient by it
// keeps the letter shapes and only repaints the *inside* of the text.
//
// `time` is supplied from SwiftUI each frame; feeding it into sin() makes the
// gradient flow. The output must be premultiplied (rgb already scaled by a),
// which is why every channel is multiplied by `color.a`.
[[ stitchable ]]
half4 aurora(float2 position, half4 color, float time) {
    // Scale screen coordinates down so the waves are a comfortable size.
    float2 p = position * 0.012;

    // Three overlapping sine waves at different speeds = organic, non-repeating motion.
    float w = sin(p.x * 1.4 + time)
            + sin(p.y * 1.7 + time * 0.7)
            + sin((p.x + p.y) * 1.1 + time * 0.5);

    // Three accent colors to blend between.
    half3 indigo = half3(0.36, 0.42, 0.96);
    half3 cyan   = half3(0.40, 0.85, 0.95);
    half3 pink   = half3(0.92, 0.45, 0.86);

    half t1 = half(0.5 + 0.5 * sin(w));
    half t2 = half(0.5 + 0.5 * cos(w * 1.3));
    half3 rgb = mix(mix(indigo, cyan, t1), pink, t2 * 0.6);

    // Keep the original alpha (the glyph shape); output premultiplied.
    return half4(rgb * color.a, color.a);
}
