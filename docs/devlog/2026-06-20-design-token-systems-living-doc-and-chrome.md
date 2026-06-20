---
lore_type: devlog
created: 2026-06-20
title: "Design token systems: living-doc de-slop + native chrome"
date: 2026-06-20
day: 3
---

**Ran an Impeccable design audit on the whole app, then built two mirrored token systems — an OKLCH-hue-parameterized palette + font selector for the living-doc HTML, and a `DesignSystem.swift` token layer the native SwiftUI chrome was bulk-migrated onto via a 10-agent workflow.**

## What got done
- **Impeccable setup:** wrote `.impeccable.md` design context (audience = the maker; "precise · warm · a-little-weird"; both themes genuinely composed; no accent stripes, no card-soup, no cyan-on-dark).
- **Living-doc audit:** scored 13/20 — flagged `border-left` accent stripes, cyan-on-dark + neon tag rainbow, `Inter`/system-only font stack, card-soup, hero-KPI template, plus a11y gaps (`outline:none`, no `:focus-visible`, hover-only controls, no tablist ARIA).
- **Living-doc de-slop** (`ProductDocGenerator.swift`): replaced the fixed palette with an **OKLCH system parameterized by a single hue** (`--h`/`--ca`) so neutrals tint toward the brand color for all four accents (amber/terracotta/ochre/olive). Added `--font-display/body/mono` variables. Killed every `border-left` stripe (callouts → full border + tint + colored label; blockquotes → dim quote glyph), flattened the hero KPI to instrument rows, tokenized the supertag chips + promote button, added `:focus-visible`, editable-region focus, `prefers-reduced-motion`, and a full WAI-ARIA tablist (roving tabindex + arrow keys). Re-scored ~17/20.
- **Settings → Document:** accent-hue swatches + font-pairing presets (System/Typewriter/Almanac/Humanist) + live pickers over `NSFontManager` installed families (Display/Body/Mono → flips to Custom). Persisted in `DashboardStore` (`docAccent`/`docFontPreset`/custom families), regenerates open docs on change. Default = System + Amber.
- **Chrome audit (native SwiftUI):** scored ~5.5/16 — 457 fixed `.font(.system(size:))` vs 41 semantic, **0** `.accessibilityLabel` across all Views, 99 `RoundedRectangle` (card-soup), hardcoded status colors colliding (purple = both "assistant" and "worktree").
- **Chrome remediation (workflow `chrome-design-remediation`):** new `DesignSystem.swift` (`DSFont`/`DSSpace`/`DSRadius`/`DSColor` + `SectionHeader` + `.cardSurface()`/`.dsHairline()`/`.dsHitTarget()`). 10 parallel agents over disjoint file buckets migrated the tree: fixed fonts **457 → 20**, `.accessibilityLabel` **0 → 59**, `RoundedRectangle` **99 → 56**, `DSColor` 190 uses, `DSSpace`/`DSRadius` 550 uses. Build green; adversarial review found no behavioral regressions.

## Decisions
- **Parameterize the whole palette by one OKLCH hue**, not per-hue hand-tuned palettes — one formula × an injected `--h` gives genuine neutral-tinting for all four accents with no 4× duplication.
- **System fonts by name, not bundled webfonts** — the living-doc renders in WKWebView on the user's own Mac, so any installed family (incl. personally-installed) resolves by name with zero network. Robust fallback stacks for portability.
- **`DesignSystem.swift` mirrors the CSS `:root`** — same token philosophy on both sides of the WebView boundary. Typography built on semantic text styles so it honors Dynamic Type while preserving density.
- **Conflict-free parallelism via file-partitioning** — the workflow assigned each agent a *disjoint* set of files (never the same file twice) in the shared working tree, so 10 agents edited concurrently with zero merge conflicts and no worktree isolation overhead.

## Issues
- **SourceKit "Cannot find DSFont/DSColor in scope" false alarms** after the bulk refactor — stale index noise (per CLAUDE.md). A forced recompile of every flagged file passed clean; trust `swift build`, not the LSP.
- **Token over-mapping nits** the review caught: a 22pt empty-state hero icon shrank to ~18pt (restored to fixed 22pt — a legit no-token exception); tiny separator chevrons that grew were mostly left at small fixed sizes (5–9pt). ~20 fixed sizes remain intentionally (tiny separators + large display glyphs).
- **Two icon-only `Menu`s** (not Buttons) initially missed the a11y pass; labeled in the fix phase.

## What to remember
- The living-doc and the native chrome now have **two parallel token systems**: CSS `:root` (hue-parameterized OKLCH, in `ProductDocGenerator.swift`) and `DesignSystem.swift` (`DS*` enums). Keep them conceptually aligned when changing either.
- `DSFont.*` are semantic/scalable; the ~20 remaining `.font(.system(size:))` are deliberate exceptions (tiny separators, big display glyphs) — don't "fix" them.
- Living-doc fonts must stay **local** (WKWebView `file://` blocks network) — bundle any non-installed face under `.assets/`, never `@import` from a CDN.
- Committed `docs/devdash/*.html` are generated output; they refresh when the app opens a Product tab after the generator changed.
- Triage drag-and-drop keyboard support is still open (owner: user).

---

## Commits
- 922f845 add keyboard shortcuts + lore-as-engine Phase 1 Tasks 3-4 _(bundled this session's design work: living-doc OKLCH/font system, Settings Document selectors, `DesignSystem.swift`, and the chrome token migration)_
