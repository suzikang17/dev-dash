---
type: devlog
title: "Day 7 — Embedded live iOS Simulator (baguette) + Build & Run"
date: "2026-06-24"
day: 7
phase: Tooling
---

**Added a "Simulator" tab that embeds a live, interactive iOS Simulator inside dev-dash — streamed framebuffer + tap/swipe/type via a user-started `baguette serve` sidecar — plus a Build & Run panel that builds an Xcode project and installs/launches it onto the booted sim. Verified end-to-end on iOS 26.4: the live embed + input, and the full build → install → launch chain (proven against a synthetic iOS app).**

## What got done

- **Engine validated first (Phase 0)** — before any app code: `brew install baguette`, booted iOS 26.4, confirmed live framebuffer capture (1206×2622 JPEGs that change frame-to-frame) and that input lands (a tap opened Settings; home/app-switcher navigated). The iOS 26 HID path the research flagged as broken-everywhere-but-baguette, confirmed working on this machine.
- **`BaguetteRunner`** — locates the `baguette` binary (mirrors `LoreRunner`), manages the `baguette serve` sidecar via `ShellRunner.start`, lists sims from `baguette list` JSON; bounded health-check on `127.0.0.1:8421`; kills the sidecar on app quit (`willTerminateNotification`) and on Stop.
- **`SimulatorView`** — new global `Selection.simulator` destination (sidebar, like `.home`, not a per-project DetailTab). States: not-installed (install hint) / idle (device picker + Start) / starting / running (WKWebView embed) / error. Explicit Start — nothing spawns until asked.
- **`SimAppRunner` (Build & Run)** — pick an Xcode project from `store.projects`, `xcodebuild` it for the booted sim, locate the `.app` + bundle id via `-showBuildSettings -json` (target whose product ends in `.app`), then `simctl install` + `launch`. Cancellable; derived data under `~/Library/Caches/dev-dash/simbuild/<slug>` so it never pollutes the target repo.

## Decisions

- **Vendor baguette over a native embed** — see [ADR 0007](../decisions/0007-embed-ios-simulator-via-baguette.md). Capture + input is private-framework + iOS-26-HID territory; baguette already gets it right, so we ride its maintenance rather than own the fragility.
- **WKWebView of baguette's own focus page** — interactive stream + input for free; the native VideoToolbox renderer is deferred to Phase 2.
- **Explicit Start, global destination** — spawning a private-framework-linked process must be intentional, and the sim isn't project-scoped, so it's a top-level `Selection`, not a `DetailTab`.

## Issues

- **Orphan-on-quit (caught in review)** — sidecar teardown was view-scoped (`onDisappear`/Stop), so Cmd-Q would reparent `baguette serve` to launchd. Fixed by registering `willTerminateNotification` in `BaguetteRunner.init`, mirroring `TerminalSessionStore`.
- **Headless snapshot looked black** — an offscreen WKWebView suspends the canvas/video pipeline, so the screen rendered black while the page chrome drew fine; a visible-window harness showed the live home screen streaming correctly. Verification artifact, not a bug.
- **Concurrent-session commit hazard** — another live session had interleaved work in `DashboardStore.swift`; staged and committed only the 7 simulator files explicitly to avoid sweeping in its unfinished work.

## Verified

- Live interactive embed renders in `WKWebView` (captured the streaming iOS 26.4 home screen via the app's exact load path); taps/buttons work; `swift build` green; two `ce-swift-ios-reviewer` passes with fixes applied (quit-leak, build cancellation, multi-target `.app` selection).
- Build & Run chain proven end-to-end against a synthetic iOS app (SimProbe): `xcodebuild build` → `-showBuildSettings -json` (JSON shape matches `BuildSettingsEnvelope`) → `simctl install` → `simctl launch`, with a screenshot confirming the app running on the booted iPhone 17 Pro. `-list -json` scheme parsing also confirmed against a real workspace.

## Picking up next session (real-project test)

The only untested path is Build & Run against a large real-world app. To resume:

1. **Prereqs:** `baguette` on PATH (`brew install baguette`, needs Xcode 26 + Apple Silicon) and an iOS sim booted (`xcrun simctl boot <udid>`, or use the in-app device picker).
2. **Run it:** open dev-dash → **Simulator** tab → **Start simulator** → in the Build & Run panel pick the real Xcode project → **Build & Run**.
3. **Watch for** (the things SimProbe couldn't surface): code-signing prompts/failures, SPM/CocoaPods dependency resolution, multi-scheme projects needing the scheme picker, and the wrong-`.app`-target case in multi-target schemes (mitigated by selecting the target whose product ends in `.app`).
4. **Success** = the app launches in the embed and is clickable; **failure** = the error tail shows in the Build panel (timeouts are labelled "Build timed out after 10 min").

Relevant code: `Scanners/SimAppRunner.swift` (pipeline), `Scanners/BaguetteRunner.swift` (sidecar), `Views/Tabs/SimulatorView.swift` (UI). Deferred: Phase 2 native VideoToolbox renderer (see ADR 0007).
