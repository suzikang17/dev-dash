#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Shared visual-effect shaders. All compiled (with Aurora.metal) into
// default.metallib by run.sh / dist.sh. Called from ShaderEffects.swift.
//
// Convention: these run via .colorEffect, so `position` (user-space pixel) and
// `color` (current pixel) are supplied implicitly; remaining params are passed
// from SwiftUI. Output is premultiplied (rgb already scaled by alpha).

// 1) AI-working shimmer — a translucent diagonal light streak that sweeps across.
// Applied to an opaque overlay rectangle; we ignore the incoming color and emit a
// mostly-transparent streak. Gated to live tasks in SwiftUI, so it only animates
// for cards whose agent is actually running.
[[ stitchable ]]
half4 aiShimmer(float2 position, half4 color, float time) {
    float d = (position.x + position.y) * 0.012 - time * 2.2;
    float streak = pow(max(0.0, sin(d)), 8.0);   // narrow, fast-falloff band
    half a = half(streak) * 0.45h;
    half3 tint = half3(0.62, 0.74, 1.0);         // cool light
    return half4(tint * a, a);
}

// 2) Health aura — a soft radial pulse behind a status dot. `rect` (.boundingRect)
// gives the view box so we can normalize; `tint` (.color) is the health color.
// The sine on `time` makes it breathe — a calm "this needs attention" nudge.
[[ stitchable ]]
half4 healthAura(float2 position, half4 color, float4 rect, float time, half4 tint) {
    float2 uv = (position - rect.xy) / rect.zw;       // 0..1 across the box
    float dist = length(uv - 0.5) * 2.0;              // 0 center → 1 edge
    float pulse = 0.5 + 0.5 * sin(time * 2.0);
    float glow = (1.0 - smoothstep(0.0, 1.0, dist)) * (0.30 + 0.40 * pulse);
    half a = half(glow);
    return half4(half3(tint.rgb) * a, a);
}

// 3) Diff gutter glow — a STATIC gradient brightest at the gutter edge, fading
// right. No `time` → zero per-frame cost. `tint` (.color) is success/danger.
[[ stitchable ]]
half4 diffGlow(float2 position, half4 color, float4 rect, half4 tint) {
    float x = (position.x - rect.x) / rect.z;         // 0 at gutter edge
    float g = pow(1.0 - clamp(x, 0.0, 1.0), 2.2);
    half a = half(0.05 + 0.16 * g);
    return half4(half3(tint.rgb) * a, a);
}

// 4) Nebula — a subtle dark generative field for empty states. Opaque output;
// the caller dials overall presence down with .opacity().
[[ stitchable ]]
half4 nebula(float2 position, half4 color, float time) {
    float2 p = position * 0.006;
    float w = sin(p.x + time * 0.25)
            + sin(p.y * 1.3 + time * 0.18)
            + sin((p.x + p.y) * 0.7 + time * 0.12);
    half t1 = half(0.5 + 0.5 * sin(w));
    half t2 = half(0.5 + 0.5 * cos(w * 1.2));
    half3 base = mix(half3(0.09, 0.11, 0.20), half3(0.17, 0.10, 0.24), t1);
    base = mix(base, half3(0.10, 0.18, 0.22), t2 * 0.5);
    return half4(base, 1.0h);
}
