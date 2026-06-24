---
lore_type: decision
title: "Embed a live iOS Simulator via the external baguette CLI, not a native CoreSimulator integration"
date: 2026-06-24
category: tooling
revisit: true
---

## Why this choice

dev-dash should let you watch and drive an iOS Simulator — and run your app on it —
without leaving the dashboard. The simulator screen is an `IOSurface` (a GPU framebuffer
readable across process boundaries), so embedding is technically possible, but every path
runs through Apple's **private** CoreSimulator/SimulatorKit frameworks, and input
injection broke on iOS 26: the old 5-argument `IOHIDEvent` signature most tools use
silently drops events or crashes `backboardd`; Xcode 26 needs the 9-argument digitizer
path.

`baguette` (Homebrew, Apache-2.0) already solves the hard parts — 60fps IOSurface
streaming over WebSocket **plus** correct iOS 26 HID input — exposed as a localhost server
with a per-sim web UI. dev-dash spawns `baguette serve` on `127.0.0.1:8421` (explicit
Start, never auto) and embeds its focus page in a `WKWebView`. Validated end-to-end on
iOS 26.4 before any app code was written: live frames + taps/buttons work.

## Options considered

- **Engine:** vendor baguette as a sidecar (chosen — rides its iOS 26 HID fix and
  per-Xcode-version maintenance) vs. build a native CoreSimulator/IOSurface embed (max
  control, but we'd own the 9-arg HID fix and every Xcode break) vs. a ScreenCaptureKit
  mirror of Simulator.app (public capture API, but mirrors a hidden window with fiddly
  input mapping).
- **Embed surface:** `WKWebView` pointed at baguette's own focus page (chosen —
  interactive stream + input for free, and dev-dash is already a heavy WKWebView user)
  vs. a native SwiftUI/VideoToolbox renderer decoding the H.264/AVCC WebSocket (more
  native, deferred to a possible Phase 2).
- **Start:** explicit button (chosen — baguette links private frameworks, so spawning
  must be intentional) vs. auto-spawn on tab open.
- **Run-your-app:** `xcodebuild` + `simctl install`/`launch` orchestration (chosen —
  durable CLI path, no private frameworks; the same language-agnostic glue any stack
  could use).

## Tradeoffs

- Gain: a live, interactive simulator in-window, plus one-click build → install → launch
  of an Xcode project onto it; the hard, fragile part (iOS 26 capture + input) is
  outsourced to a focused upstream.
- Give up: a runtime dependency on the `baguette` binary (`brew install baguette`,
  requires Xcode 26 + Apple Silicon) that is invisible from the Swift; reliance on
  baguette's web UI and private-framework linkage, both of which can break across Xcode
  versions (revisit flagged); a localhost sidecar we must lifecycle-manage (kill on
  quit/Stop).
- Not done: the native renderer (Phase 2). The build → install → launch chain is proven
  end-to-end against a synthetic iOS app (build, settings-JSON parse, install, launch all
  confirmed); a build against a large real-world project (signing, SPM/CocoaPods deps) is
  still untested.

## Build stages

1. `BaguetteRunner` — locate the binary, manage the `serve` lifecycle, list sims;
   terminate the sidecar on app quit (`willTerminateNotification`) and on Stop.
2. `SimulatorView` — global `Selection.simulator` destination;
   not-installed / idle / starting / running / error states; WKWebView embed.
3. `SimAppRunner` — Build & Run: `xcodebuild` → `-showBuildSettings -json` →
   `simctl install`/`launch`; cancellable; derived data kept outside the target repo.
4. (Deferred) Phase 2 native VideoToolbox renderer that drops the embedded web UI.
