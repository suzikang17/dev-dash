---
lore_type: decision
title: "Native Metal shaders for UI accents via a precompiled metallib"
date: 2026-06-25
category: tooling
revisit: true
---

## Why this choice

We wanted GPU-driven visual accents — an animated gradient title, a "this agent is working" shimmer, a stale-project aura, a diff-gutter glow, drifting empty-state fields. SwiftUI exposes Metal fragment shaders directly through `.colorEffect`/`.layerEffect`/`.distortionEffect` (macOS 14+), which is the elegant path: a `[[stitchable]]` function in a `.metal` file plus a thin `.someEffect()` modifier.

The catch is **compile timing**. SwiftUI's `ShaderLibrary.default` resolves functions from a **precompiled** `default.metallib` in `Bundle.main`. Two facts forced the decision:

1. **SwiftPM does not compile `.metal` files.** `swift build` silently ignores them — no metallib is produced.
2. **`xcrun metal` is a stub in current Xcode.** The real offline compiler ships as a separate ~688MB "Metal Toolchain" component (`xcodebuild -downloadComponent MetalToolchain`).

The alternative — compiling shader *source* at runtime via `MTLDevice.makeLibrary(source:)` — needs no toolchain download, but SwiftUI's `ShaderLibrary` only accepts precompiled libraries, so it would mean dropping out of SwiftUI into a hand-rolled `MTKView` for every effect.

We chose the precompiled-metallib path: keep the clean SwiftUI call sites, pay the one-time toolchain cost, and own the compile step in our build scripts.

## Decision

1. **Shaders live in `Sources/DevDash/Shaders/*.metal`** (`Aurora.metal`, `Effects.metal`), each a `[[stitchable]]` fragment function. They are *not* part of the SwiftPM target's compiled sources.
2. **`run.sh` and `dist.sh` compile them into the app bundle**: `xcrun metal -o DevDash.app/Contents/Resources/default.metallib Sources/DevDash/Shaders/*.metal`, run **before** `codesign` so the metallib is signed in. This is consistent with the existing "cp binary into `.app`" packaging trick where `Bundle.main` is the `.app`.
3. **SwiftUI wraps each effect in a thin modifier/view** in `ShaderEffects.swift` (`.auroraText()`, `.workingShimmer(active:)`, `.healthAura(_:active:)`, `DiffGlowBackground`, `NebulaBackground`). Adding an effect is "append a function to a `.metal` file + a small modifier" — no new build wiring.
4. **Effects are signal-carrying and self-throttling.** Animated effects (`TimelineView(.animation)`) are gated by an `if active`/branch so the animation is never built when idle; the GPU is only driven while the relevant state is on screen. Shaders that don't need motion (the diff glow) are static.
5. **Shaders never go on dense lists unguarded.** The diff-gutter glow falls back to a flat fill past 400 rows, because a per-cell `colorEffect` on a thousand-row diff is real GPU cost with no perceptible payoff at gutter scale.

## Consequences

- **Build dependency:** producing a correct build now requires the Metal Toolchain component. A plain `swift build` (or a build on a machine without the toolchain) yields a binary with **no metallib** — effects degrade gracefully to no-ops (solid color / no glow), they do not crash. Documented in both build scripts' comments.
- **Graceful degradation is load-bearing:** `ShaderLibrary.default.<fn>` resolves lazily and fails soft, so a missing/partial metallib is a cosmetic loss, not a runtime error.
- **One shared metallib:** all shaders compile into a single `default.metallib`; adding functions is cheap and needs no per-shader plumbing.

## Alternatives considered

- **Runtime-compiled `MTKView`** — no toolchain download, but abandons SwiftUI's shader API and adds an `NSViewRepresentable` + full render pipeline per effect. Rejected: far more code, loses the one-line call sites.
- **Let SwiftPM compile `.metal` into the resource bundle** — doesn't work (SwiftPM ignores `.metal`), and the resource bundle isn't `Bundle.main` under our packaging trick anyway.
- **No shaders / fake it with stacked SwiftUI gradients on the CPU** — janky for the animated cases and can't express the per-pixel effects at all.

## Revisit if

The toolchain dependency becomes a CI/onboarding burden, Apple changes how `metal`/metallibs ship, or the accents stop earning their cost (battery, distraction). At that point, reconsider runtime compilation or dropping the purely-decorative effects.
