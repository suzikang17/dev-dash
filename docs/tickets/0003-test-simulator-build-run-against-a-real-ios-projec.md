---
lore_type: ticket
created: '2026-06-24'
title: Test simulator Build & Run against a real iOS project
status: open
owner: human
category: engineering
ai_run: false
migrated_from: "0003"
---
# Test simulator Build & Run against a real iOS project

The embedded Simulator feature (ADR 0007, committed `d96a0a1`) is verified end-to-end
*except* the Build & Run pipeline against a large real-world app. It was proven against a
synthetic single-file app (SimProbe): `xcodebuild build` → `-showBuildSettings -json` →
`simctl install` → `simctl launch` all work and the JSON shapes match the parser. What a
real project could still surface: code signing, dependency resolution, and multi-scheme
/ multi-target selection.

## How to test

1. **Prereqs:** `baguette` on PATH (`brew install baguette`, needs Xcode 26 + Apple
   Silicon) and an iOS sim booted (`xcrun simctl boot <udid>`, or use the in-app picker).
2. **Run it:** dev-dash → **Simulator** tab → **Start simulator** → in the Build & Run
   panel pick the real Xcode project → **Build & Run**.
3. **Success** = the app builds, installs, launches, and is clickable in the embed.
   **Failure** = the error tail shows in the Build panel (timeouts are labelled
   "Build timed out after 10 min").

## Watch for (things SimProbe couldn't surface)

- **Code signing** — sim builds set `CODE_SIGNING_ALLOWED=NO`; a real project's settings
  may still prompt or fail. Confirm `SimAppRunner` overrides/handles this.
- **Dependencies** — SPM resolution / CocoaPods (`.xcworkspace`) on first build; build
  may take minutes (600s timeout) or fail on missing pods.
- **Scheme selection** — multi-scheme projects should show the scheme picker; verify the
  right one is pickable and remembered.
- **Multi-target schemes** — product/bundle-id resolution selects the target whose
  product ends in `.app`; confirm it picks the app, not an extension/test target.
- **derivedData** — lands in `~/Library/Caches/dev-dash/simbuild/<slug>`, not the target
  repo; confirm no untracked artifacts appear in the project.

## Relevant code

- `Sources/DevDash/Scanners/SimAppRunner.swift` — build/install/launch pipeline + state machine
- `Sources/DevDash/Scanners/BaguetteRunner.swift` — `baguette serve` sidecar lifecycle
- `Sources/DevDash/Views/Tabs/SimulatorView.swift` — Build & Run panel UI

Deferred (out of scope for this task): Phase 2 native VideoToolbox renderer (see ADR 0007).
