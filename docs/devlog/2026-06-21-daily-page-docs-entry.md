---
lore_type: devlog
created: 2026-06-21
title: "Daily-page docs entry (Roam × Tana outliner)"
date: 2026-06-21
day: 4
---

**Built a Roam-style Daily-page entry into docs: the Today tab is now an infinite scroll of editable bullet outlines (one `note` doc per day), where any bullet can be supertagged into any lore type — shipped via a two-phase autonomous workflow build.**

## What got done
- Reshaped the **Today** tab from a read-only timeline into an **infinite scroll of editable daily pages**, newest on top. Each day is one `note` doc (`docs/notes/YYYY-MM-DD.md`) whose body is a markdown bullet list.
- Native SwiftUI **outliner**: `BulletRow` (NSTextField via `NSViewRepresentable`) intercepts the field editor's command selectors — Return→new sibling, Tab/Shift-Tab→indent/outdent, Backspace-at-0→merge, Up/Down→focus move. `OutlinerView` composes rows, owns focus, and routes every mutation through pure `DayOutline` ops.
- **Tana-style supertags**: a `#` picker on any bullet extracts its subtree into a real typed lore doc (task/idea/kpi/decision/devlog/overview — discovered dynamically from `SupertagRegistry`, never hardcoded) and leaves a `[[backlink]]` in the outline. Extraction is deterministic (no `claude -p`).
- **Live file-watch** (`NotesFileWatcher`, DispatchSource over `docs/notes/`) so bullets Claude Code writes during work appear automatically; the actively-edited day is never clobbered.
- Pure logic (`DayOutline`, `DailyPageStore`, `SupertagRegistry`, `LoreDocWriter`) is verified by a new headless `DevDash --daily-selftest` subcommand (49 assertions), mirroring the existing `TerminalSelfTest`/`DocRegenCLI` pattern — there's no XCTest target.

## Decisions
- **One file per day, not one file per note.** The outliner choice (indent/reorder/fold) is dramatically simpler and more robust as a single markdown list per day than as bullets spread across files needing an ordering index. Supertagging extracts a bullet to its own typed doc; the daily page keeps a backlink. Reconciles Roam's daily page with Tana's tagging while staying lore-native.
- **Supertag set = the live lore registry**, so it stays correct as types are added/ejected (`note` is the default bullet state, so it's excluded from the picker).
- **Deterministic doc authoring** (hand-written frontmatter from `LoreSection.newDocFields` + schema), not `lore add`'s AI body generation — keeps extraction fast and selftestable.
- **Built it with the phased-autonomous-build workflow**: Phase 1 (logic, Tasks 1–5) and Phase 2 (UI, Tasks 6–10) each ran as a background Workflow — sequential implementers → adversarial Opus review with a fix loop → Opus final — gated on `swift build` + `--daily-selftest`.

## Issues
- **`focusedDate` was never cleared** — once you typed in today's page it stayed "focused" forever, so the watcher would never reload it. That silently broke the core promise (Claude appends to *today's* file during work, and you'd never see it). Fixed by clearing `focusedDate` when the debounced save flushes (~0.6s after the last keystroke), so the day becomes refresh-eligible again without ever clobbering a mid-edit.
- **Project-switch state leak** — switching projects kept stale `outlineByDate` entries (keyed by date) and left the watcher pointed at the old project's `docs/notes`. Fixed in the `project.path` change handler (clear pages/focus, restart watcher).
- **Plan bug caught at the between-phase checkpoint**: Task 10 iterated `ForEach(days)`, which only contains dates that have docs/sessions — so today wouldn't appear with no docs yet, breaking "land on today and type." Fixed by injecting today into `reload()`'s date set before Phase 2 ran.
- Phase-1 implementers left two files modified-but-uncommitted (scope leakage); the independent re-verify caught it. One was a genuine empty-day-spinner fix, committed separately.
- SourceKit "Cannot find X in scope" noise persisted throughout — `swift build` is ground truth (per CLAUDE.md), and it stayed green.

## What to remember
- The daily page path contract is `docs/notes/YYYY-MM-DD.md` with `title`/`created` frontmatter; `DailyPageStore.write` preserves any existing frontmatter and replaces only the body. Indentation unit is **2 spaces per depth**.
- The watcher deliberately refreshes **non-focused days only**; "focused" is released on save-flush, not on a real blur event — a true on-blur reconcile is still a future improvement.
- **Deferred (designed-around, not built):** in-row `[[` autocomplete (backlinks are clickable, typeahead isn't wired into the NSTextField row yet), drag-to-reorder, soft line breaks within a bullet, multi-tag per node. See the spec/plan under `docs/superpowers/`.
- **Not auto-verified:** the outliner's actual feel — typing, indent/outdent, supertag extraction writing a real doc, live-refresh — needs a human `bash run.sh`. The selftest only covers the model/IO/extraction logic, not the SwiftUI/AppKit interaction layer.

---

## Commits
- 2190498 spec: daily-page docs entry (Roam x Tana, lore-native outliner)
- 3889ce8 spec: supertags = all registered lore types (dynamic, not hardcoded)
- ca17fa5 plan: daily-page docs entry implementation plan
- d56e905 plan: fix Task 10 (match current DailyTabView structure + today always present)
- 36c79e1 daily: outline model + markdown round-trip + headless selftest
- de9c7b4 daily: pure outline ops (insert/indent/outdent/merge/flatten)
- 1eda3b9 daily: DailyPageStore per-day file IO (frontmatter-preserving)
- 6c31f1d daily: SupertagRegistry (all lore types, schema-aware)
- 920c054 daily: LoreDocWriter (doc content + supertag extraction)
- edb0755 daily: empty-timeline state + loaded flag (fix empty-day spinner)
- 7ce32d5 daily: BulletRow NSTextField with outline key interception
- 3e34e04 daily: OutlinerView (rows + key ops + focus)
- 335601f daily: supertag picker + extraction wiring
- da4b1ee daily: NotesFileWatcher (DispatchSource, debounced)
- 529c850 daily: infinite-scroll editable day pages + live file-watch
- 3d7d2f2 daily: fix watcher/state on project switch + live-refresh focused day after save flush
