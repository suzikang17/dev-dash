# Preview tab: iOS simulator mode

**Date:** 2026-06-27
**Status:** Approved — implementing

## Problem

The live iOS Simulator (baguette embed + build→install→launch pipeline) lives only
in a **global** Simulator destination, where you manually pick a project. There's no
way to launch it in the context of the project you're already looking at. And the
Preview tab — the natural place to "see the app" — can't show an iOS app at all:

- `PreviewTabView` routes pure-Apple projects to `AppleAppPreview`, a buttons-first v1
  whose iOS support is just an "Open Simulator.app" button (no live embed, no pipeline).
- `isAppleProject` keys off a project's single `framework` classification, so a project
  like **pet-homepage** (classified Next.js, with its Xcode project in `ios/`) never
  reaches it — the iOS app is invisible to the Preview tab.

## Goal

The Preview tab can show a **web app**, an **iOS app**, or — for a project that has
both — let you switch between them. The iOS view is the real live simulator embed with
Build & Run, scoped to the current project.

## Approach

Extract the simulator machinery `SimulatorView` already has (baguette server lifecycle,
the live `WKWebView` embed, and the `SimAppRunner` build→install→launch pipeline) into a
reusable, project-scoped **`SimulatorEmbedView(fixedProject:)`**, and host it as a new
**iOS mode in the Preview tab**.

- Global Simulator destination → `SimulatorEmbedView(fixedProject: nil)` (user picks a
  project — current behavior preserved).
- Preview tab iOS mode → `SimulatorEmbedView(fixedProject: currentProject)` (no project
  picker; auto-resolved).

Rejected alternatives: (a) a fresh duplicate iOS preview view → two copies of the build
pipeline that drift; (b) extending `AppleAppPreview` → it has no live embed, so this
would be more work than reusing the real thing.

## Detection

Computed for the selected project:

- `hasWebPreview` — an effective URL exists (running dev service or custom URL).
  *(today's web-preview condition, unchanged)*
- iOS app — resolved via a helper that classifies a discovered Xcode project as iOS:

  ```swift
  func iosProject(for project: Project) -> XcodeProject? {
      guard let xp = XcodeProject.discover(name: project.name, rootPath: project.path) else { return nil }
      if project.framework == "iOS App" { return xp }   // scanner already classified it
      if xp.rootPath != project.path { return xp }       // found in a subdir, e.g. ios/
      return nil                                          // root-level xcodeproj on a non-iOS project ⇒ likely macOS
  }
  ```

  This catches pet-homepage (`ios/PetHomepage.xcodeproj`) and pure iOS apps, while not
  misrouting a root-level macOS app's `.xcodeproj` to the iOS simulator. It is a
  heuristic (no `xcodebuild` platform probe) — acceptable for v1. Relies on the recursive
  `XcodeProject.discover` (now scans one level deep, skipping `node_modules`/`Pods`/etc.).

  Resolved into `@State` on appear / selection change (disk I/O), not per body pass.

## Preview tab routing

1. `proj == nil` → "No preview available" *(unchanged)*
2. macOS/SPM Apple project (Apple framework, **not** iOS, no web service) → `AppleAppPreview` *(unchanged)*
3. iOS app **and** web → **Web | iOS** segmented switcher; body renders the selected mode.
   Default to last-used mode (persisted per project), else Web.
4. iOS app only → `SimulatorEmbedView(fixedProject: proj)` directly (no switcher).
5. web only → web preview *(unchanged)*
6. neither → not-running / no-preview *(unchanged)*

Per-project mode memory: UserDefaults dict keyed by project path (mirrors `TabStore`'s
per-project tab memory pattern).

## `SimulatorEmbedView(fixedProject:)`

Extracted from `SimulatorView`'s body; states unchanged:
not-installed → idle (device picker + Start) → starting → running (embed + Build & Run).
Owns `BaguetteRunner`, `SimulatorWebHolder`, `SimAppRunner` as `@StateObject`s. Renders a
slim header (icon + title + Stop-when-running); title = `fixedProject?.name ?? "Simulator"`.

`BuildAndRunPanel` gains a `locked` flag: when set (fixed project), it hides the project
picker and the folder fallback and shows the project name as a label; scheme picker still
appears when there's more than one scheme.

`xcodeProjects`:
- `fixedProject != nil` → `[discover(fixedProject)]` (or empty)
- else → `store.projects.compactMap(discover)` *(current global behavior)*

Each instance owns its own baguette server, stopped on `onDisappear` (as today), so the
Preview-hosted instance tears down its server when you leave iOS mode / the project.

## Files

- **New** `Sources/DevDash/Views/SimulatorEmbedView.swift` — `SimulatorEmbedView`,
  `BuildAndRunPanel` (with `locked`), `SimulatorWebHolder`, `SimulatorWebView`
  (moved from `SimulatorView.swift`).
- **Modify** `Sources/DevDash/Views/Tabs/SimulatorView.swift` → thin wrapper:
  `SimulatorEmbedView(fixedProject: nil)`.
- **Modify** `Sources/DevDash/Views/Tabs/PreviewTabView.swift` → mode switcher + routing
  + `iosProject` helper + per-project mode memory.

## Out of scope

- Side-by-side "both" split view (switcher-first; split is a later follow-up).
- Changing the global Simulator destination's UX.
- `xcodebuild` platform probing for iOS detection (heuristic is enough for v1).
