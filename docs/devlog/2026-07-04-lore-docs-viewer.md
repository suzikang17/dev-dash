---
lore_type: devlog
created: 2026-07-04
title: "Lore docs viewer: Docs tab with editorial reading pane + wikilink graph"
date: 2026-07-04
day: 17
---

**Added a Docs detail tab (and, via PanelKind, a canvas panel): a type-grouped, searchable sidebar over every `docs/<dir>/*.md`, and a styled HTML reading pane with clickable `[[wikilinks]]` and a backlinks footer.**

## What got done

- `LoreDocsScanner` (new): generic enumeration of `docs/<dir>/*.md` (skips `index.md`, dot-dirs) → `LoreDocGroup`/`LoreDoc` with frontmatter, newest first. Any repo's custom lore types show up without code changes.
- `DocsTabView` (new): sidebar (search, collapsible type sections with counts + type-colored dots, status/date on rows) + reading pane (WKWebView). Toolbar with Reveal in Finder / open in default editor. Live-refreshes via `NotesFileWatcher` (armed once per project) when the lore CLI writes docs.
- `LoreDocHTML`: editorial page — type-tinted pill + numeric id kicker, `ui-serif`/New York display title, meta chips (date, day, status pill, owner/phase), 760px measure body via `Markdown.bodyHTML`, tinted blockquotes/code, per-type accent color, light/dark via `color-scheme` + `color-mix` (same pattern as `Markdown.stylesheet`).
- Wikilinks: pre-converted (fence- and inline-code-aware, mirroring `LoreLinkIndex.wikilinks`) to markdown links with `lore://open/<percent-encoded path>` hrefs; `DocWebView`'s navigation delegate routes them to in-app navigation and real URLs to the browser. Backlinks footer from `LoreLinkIndex.Graph`. Task checkboxes prettified (`- [ ]` → ☐).
- Wiring: new `DetailTab.docs` case — tab strip, ⌘-number shortcut, and the canvas "add panel" menu all pick it up from `allCases`; `defaultSize` 880×640.

## Decisions

- **HTML reading pane over native SwiftUI text**: matches the Product tab's approach, gets real typography (serif display, measure, `color-mix` tints) cheaply, and reuses the hardened `Markdown.bodyHTML` (escapes raw HTML → no injection from doc content).
- **`lore://` links via markdown pre-processing** rather than post-processing HTML: `Markdown.processInline` escapes everything up front, so injected anchors would be neutralized; markdown links survive, and `safeHref` only blocks script-y schemes so `lore://` passes.

## Issues

- Stale-completion races (slow scan for project A landing after switching to B; slow render landing after clicking another doc) — guarded at write-back with the same pattern as ProductTabView/ChangesTabView. The review pass flagged the identical issue independently.
- Doc titles containing `]` would terminate the generated markdown link early (the minimal converter has no escape syntax) — brackets softened to parens in link text.
- `swift build` must run from the repo root: the link step embeds `Info.plist` by relative path, so a drifted CWD fails with `ld: file cannot be open()ed … Info.plist`.

## What to remember

- `LoreLinkIndex.bodyOf` is now internal — the shared way to strip frontmatter before rendering a doc body.
- `DocTypeStyle` holds the dir → color mapping twice (SwiftUI `Color` + CSS hex, kept in sync by hand) — update both when adding a lore type color.
