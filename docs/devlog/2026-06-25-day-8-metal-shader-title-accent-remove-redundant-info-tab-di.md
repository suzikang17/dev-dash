---
lore_type: devlog
created: '2026-06-25'
title: Day 8 — Metal shader title accent + remove redundant Info-tab diff
date: "2026-06-25"
day: 8
phase: Polish
---
# Day 8 — Metal shader title accent + remove redundant Info-tab diff

**A curiosity detour that turned into two clean commits: a real Metal fragment shader animating the Info-tab project title, and the removal of the duplicate diff viewer that shader work surfaced.**

## What got done

- **Aurora shader title** — `Sources/DevDash/Shaders/Aurora.metal` is a `[[stitchable]]` fragment shader applied to the Info-tab project name via a `.colorEffect`. A reusable `.auroraText()` modifier (`Views/ShaderEffects.swift`) drives it from `TimelineView(.animation)`, feeding a wrapped `time` value so three overlapping sines flow an indigo→cyan→pink gradient *inside* the glyphs (multiplying by `color.a` preserves letterforms).
- **Build wiring** — `run.sh` and `dist.sh` now compile `Sources/DevDash/Shaders/*.metal` into `default.metallib` inside `DevDash.app/Contents/Resources/` **before** codesign, so `ShaderLibrary.default` (which reads `Bundle.main`) resolves it under the cp-binary-into-.app build trick.
- **Removed redundant diff viewer** — the Info-tab Git card's lightweight `DiffSheet` (raw `git diff` text dump) duplicated the real review surface in the Changes tab (`SideBySideDiffView`). Deleted the Diff button, its state, `DiffSheet`/`DiffLineView`, and the now-dead `gitDiff` store + `GitStatusScanner.diff` helpers.

## Decisions

- **SwiftUI `.colorEffect` over a runtime MTKView** — chose the elegant precompiled-metallib path, which required installing the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, ~688MB) since modern Xcode ships `metal` as a stub. The runtime-compiled `MTLDevice.makeLibrary(source:)` path would have avoided the download but meant dropping out of SwiftUI into an `MTKView`.
- **Shaders are a capability tool, not a speed tool** — confirmed during discussion: SwiftUI already composites on the GPU, so a shader *adds* a per-pixel pass (and animated ones force per-frame redraws). Use them for effects you otherwise couldn't afford, not to "accelerate" already-cheap UI. The diff tree's real lever is virtualization (`LazyVStack`), not Metal.
- **Two diff renderers were redundant, three were not** — `DiffSheet` (raw text) vs `SideBySideDiffView` (parsed, side-by-side, lazy) were organic-growth duplicates; `VisualDiffSheet` (screenshot/pixel diff) is a genuinely different job and stays.

## Issues

- **`metal` is a stub in current Xcode** — `xcrun metal` fails with "missing Metal Toolchain" until the component is downloaded separately. Documented the requirement in both build scripts' comments.
- **Graceful degradation** — if the metallib is absent (e.g. a build without the toolchain), `.colorEffect` no-ops and the title renders as a solid color rather than crashing.

## Verified

- `swift build` clean after each change; `bash run.sh` launches and the app stays up (no crash, shader renders).
- `code-reviewer` pass on the diff removal: no orphaned references, `GitCard` HStack still structurally valid, no cross-file breakage.
- Split into two independently-revertable commits: `8128b1b` (diff cleanup) and `e96f04a` (shader).
