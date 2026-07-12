---
lore_type: devlog
created: 2026-07-12
title: "Docs tab wiki-root support"
date: 2026-07-12
day: 25
---

**The Docs tab now renders wiki-profile lore repos (type dirs at the repo root), so both wikis — ~/dev/wiki and the new ~/Documents/wiki life wiki — are viewable side by side in one UI via canvas panels.**

## What got done

- `LoreDocsScanner.docsRoot(projectPath:)`: a repo with `.lore/config.yaml` at the top level (lore wiki profile) serves docs from the repo root; project-profile repos keep `docs/`. Single source of truth for the docs base path.
- Threaded `docsRoot` through `LoreDocsScanner.scan`/`load`, both `LoreLinkIndex` passes (graph build + `allDocs` autocomplete), and `DocsTabView` (NotesFileWatcher dirs + WKWebView file URL / read-access root).
- `FrameworkDetector`: a lore root now detects as stack `"lore"` (`detectStack`) and framework `"Wiki"` (`detectFromFiles`, purple `#6b5ca5`), so docs-only wiki repos register as projects at all — previously they had no detectable stack and were invisible to `ProjectScanner`.
- Added `~/Documents/wiki/` to `devdash.devRoots` defaults (com.suki.devdash); `~/dev/wiki` was already covered by the `~/dev` scan root. Launched the new build.

- **Wikis sidebar tab**: new `SidebarTab.wikis` segment (books icon) between Projects and Infra listing wiki repos (`framework == "Wiki"`) via a dedicated `SidebarWikiRow` — purple book icon, derived display name ("dev wiki" / "life wiki" — both folders are literally named `wiki`), abbreviated path, live-session dot. Wikis are excluded from the Projects tab's ungrouped list so they live in exactly one place. Seeded `devdash.lastTabPerProject` so both wikis open on the Docs tab first-time.

- **Afternoon release — the wiki became an app**: pipe tables in both markdown converters (Markdown.bodyHTML is the one the Docs tab uses — patching MarkdownWebView first was a miss); relative .md links route in-pane, other files open an in-app FileWebView sheet; "Start here" group for root-level docs; section dirs (`self/`) via one-level scanner recursion; **Edit with Claude** (sparkle button: webview-selection capture → prompt sheet → interactive session in the terminal drawer via the task-launch pattern); **collection view** (anchor doc = front cover + continuous scroll of its nested collection, IntersectionObserver scrollspy drives sidebar tracking + auto-scroll, recent/A-Z toggle); **in-place editing** (pencil toggle; pure-bullet docs → OutlinerView, mixed docs → raw editor — DayOutline.parse is lossy on mixed content, so the outliner is gated by an outline-safety check).

## Decisions

- Wiki detection keys on `.lore/config.yaml` presence, not profile parsing — cheap existence check on the scan path, and a project-profile repo is unaffected because its `.lore` lives under `docs/`.
- Two wikis stay two projects (dev wiki vs life wiki, split earlier today by user ruling: `~/dev/wiki` is dev-only, `~/Documents/wiki` holds personal/life content). One-UI viewing = pin two Docs panels on the canvas, not a merged tree.

## Issues

- SourceKit flagged "Cannot find LoreReader in scope" during the edit — the stale-index noise CLAUDE.md documents; `swift build` clean on first try.
- Upstream: `lore init <absolute-path>` nested the target under cwd (`join` vs `resolve`) — fixed in the lore repo itself (`63a957c` there), found while creating the life wiki.

## What to remember

- Anything that resolves a lore doc path must go through `LoreDocsScanner.docsRoot` now — hardcoding `<project>/docs/` breaks wiki-profile repos. `DailyTabView` still reads `<project>/docs` directly (line ~449); wikis have no daily digest so it's inert, but it's the known stragglers if wiki entries should ever join Daily.
- Wiki repos surface extra root dirs as sidebar groups (e.g. `self-audit-2026-07/` in the life wiki) — any root dir containing `.md` participates. That's the existing generic-scan behavior, now just applied at the root.

---

## Commits

- 04dd7c6 Docs tab: support wiki-profile lore roots (type dirs at repo root)
