---
lore_type: devlog
created: '2026-06-25'
title: "Day 8 — Metal shaders: animated title + four signal-carrying effects, Info-tab diff cleanup"
date: "2026-06-25"
day: 8
phase: Polish
---
# Day 8 — Metal shaders: animated title + four signal-carrying effects, Info-tab diff cleanup

**A curiosity detour that compounded: a real Metal fragment shader animating the Info-tab title, then four more *signal-carrying* shader effects (working shimmer, health aura, diff glow, empty-state nebula), the removal of a duplicate diff viewer the work surfaced, and an ADR to record the pattern.**

## What got done

- **Aurora shader title** — `Sources/DevDash/Shaders/Aurora.metal` is a `[[stitchable]]` fragment shader applied to the Info-tab project name via a `.colorEffect`. A reusable `.auroraText()` modifier (`Views/ShaderEffects.swift`) drives it from `TimelineView(.animation)`, feeding a wrapped `time` value so three overlapping sines flow an indigo→cyan→pink gradient *inside* the glyphs (multiplying by `color.a` preserves letterforms).
- **Build wiring** — `run.sh` and `dist.sh` now compile `Sources/DevDash/Shaders/*.metal` into `default.metallib` inside `DevDash.app/Contents/Resources/` **before** codesign, so `ShaderLibrary.default` (which reads `Bundle.main`) resolves it under the cp-binary-into-.app build trick.
- **Removed redundant diff viewer** — the Info-tab Git card's lightweight `DiffSheet` (raw `git diff` text dump) duplicated the real review surface in the Changes tab (`SideBySideDiffView`). Deleted the Diff button, its state, `DiffSheet`/`DiffLineView`, and the now-dead `gitDiff` store + `GitStatusScanner.diff` helpers.
- **Four signal-carrying shader effects** (`Shaders/Effects.metal` + `ShaderEffects.swift`) — `aiShimmer`: a light streak sweeps a task row *only while its agent is running* (`kanbanColumn == .aiWorking`). `healthAura`: a soft breathing glow behind a `.stale` project's health dot. `diffGlow`: a static gutter-anchored glow on changed diff cells. `nebula`: a subtle drifting field behind empty states (Info tab, task list). All reuse the existing `default.metallib` plumbing — adding effects is "append a function + a thin modifier."
- **ADR 0011** — recorded the shader pattern + build-pipeline decision in `docs/decisions/` (precompiled metallib over runtime MTKView, compiled by `run.sh`/`dist.sh` before signing, graceful degradation when absent).

## Decisions

- **SwiftUI `.colorEffect` over a runtime MTKView** — chose the elegant precompiled-metallib path, which required installing the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, ~688MB) since modern Xcode ships `metal` as a stub. The runtime-compiled `MTLDevice.makeLibrary(source:)` path would have avoided the download but meant dropping out of SwiftUI into an `MTKView`.
- **Shaders are a capability tool, not a speed tool** — confirmed during discussion: SwiftUI already composites on the GPU, so a shader *adds* a per-pixel pass (and animated ones force per-frame redraws). Use them for effects you otherwise couldn't afford, not to "accelerate" already-cheap UI. The diff tree's real lever is virtualization (`LazyVStack`), not Metal.
- **Two diff renderers were redundant, three were not** — `DiffSheet` (raw text) vs `SideBySideDiffView` (parsed, side-by-side, lazy) were organic-growth duplicates; `VisualDiffSheet` (screenshot/pixel diff) is a genuinely different job and stays.
- **Animate only what carries signal, and gate it** — every animated effect sits behind an `if active` branch so its `TimelineView(.animation)` is never built when idle; the GPU is only driven while the relevant state is on screen. Static effects (diff glow) skip `TimelineView` entirely.
- **Shaders never go on dense lists unguarded** — the diff glow falls back to a flat fill past 400 rows, because a per-cell `colorEffect` on a thousand-row diff is real GPU cost with no perceptible payoff at gutter scale (the "shaders aren't free on lists" lesson, made concrete).

## Issues

- **`metal` is a stub in current Xcode** — `xcrun metal` fails with "missing Metal Toolchain" until the component is downloaded separately. Documented the requirement in both build scripts' comments.
- **Graceful degradation** — if the metallib is absent (e.g. a build without the toolchain), `.colorEffect` no-ops and the title renders as a solid color rather than crashing.
- **Reviewer caught a real perf regression** — the `ce-swift-ios-reviewer` pass flagged (at 80 confidence) that the diff glow added a per-cell Metal pass to a potentially thousand-row `LazyVStack`. Fixed with the 400-row flat-fill fallback before commit, rather than shipping the jank.

## Verified

- `swift build` clean after each change; `bash run.sh` launches and the app stays up (no crash; all five shader functions compile — `default.metallib` grew 7KB → 37KB).
- `code-reviewer` pass on the diff removal: no orphaned references, `GitCard` HStack still structurally valid, no cross-file breakage.
- `ce-swift-ios-reviewer` pass on the four-effect batch: gating verified (inactive rows build no animation; nebula stops when its empty state leaves the hierarchy), no retain cycles, exhaustive `rowBackground` switch — one perf finding, fixed.
- Commits, all independently revertable: `8128b1b` (diff cleanup), `e96f04a` (title shader), `6c966fe` (four effects), `6ab1016`/`488559d`/`69190ef` (ADR 0011 + decisions reindex/renumber).
