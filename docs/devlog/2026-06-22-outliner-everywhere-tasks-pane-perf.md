---
lore_type: devlog
created: 2026-06-22
title: "Outliner everywhere: editable backlinks, tasks pane, delete, perf"
date: 2026-06-22
day: 5
---

**Pushed the daily-page outliner everywhere — editable docs and tasks as bullet outliners, clickable/auto-creating `[[page]]` links, task quick-add/title/delete — and killed the per-save reload+graph perf hotspot.**

## What got done
- **Inline supertags:** typing `title #task` (then space/Enter) in a bullet extracts it into a typed lore doc and leaves a `[[backlink]]`; the `#tag` token is stripped from the title. The `#` button path strips a trailing tag too.
- **Docs are bullet outliners.** Clicking a `[[backlink]]` opens the doc in the right pane as the same editable outliner (everything is bullets; non-list body lines are bulletized on load). Retired the brief Typora-style `MarkdownLiveEditor` experiment — the render-when-blurred / raw-when-focused bullet model is the single editing surface.
- **`[[page]]` link UX:** clicking a pure-link bullet **opens** the page (creating the note if it doesn't exist yet — Roam-style), with a small ✎ to edit the bullet instead. Normal bullets edit on click.
- **Open a page straight into editing:** the doc pane autofocuses the first bullet; empty docs get one empty bullet; merely opening never writes to disk (loaded-body baseline).
- **Tasks (Lore source):** each task opens in a right-pane bullet outliner (body autofocus + autosave), with an **editable title**, **inline quick-add** (type a title + Enter → creates and opens), **delete** (trash button + ⌫ key, both confirmed). Editable backlink doc pane and tasks both got delete.
- **Daily view:** Claude sessions band expanded by default (collapsible per day).
- **Perf:** task edits now update one task in place and rebuild the backlink graph off-main/coalesced instead of re-reading all docs + rebuilding the graph synchronously on every save; the outliner stopped doing an O(n) tree flatten per row (was O(n²) per render).

## Decisions
- **Everything is bullets, one editor.** Rather than a separate WYSIWYG editor per surface, the bullet outliner (markdown-rendered when not focused, raw when editing) is reused for daily pages, docs, and task bodies. Consistent, less code.
- **Link vs edit, settled:** a pure `[[page]]` bullet treats *click = open* (the natural link action) with an explicit ✎ for editing; normal bullets *click = edit*. This ended several flip-flops caused by SwiftUI `Text`+inline-`.link` hit-testing.
- **Persist tasks through the store, not the file directly** — the right pane edits via the existing `setBody`/`setField` paths so persistence stays consistent.

## Issues
- **SwiftUI `Text` with inline `.link` eats taps:** a link-bearing `Text` intercepts taps across its bounds, so background/edit layers never fire. Fix was to drop `Text` link interaction entirely and use plain `Button`s for hit-testing.
- **Autosave dropped focus** in two places: (a) keying the task detail pane by `task.id` (a fresh UUID every reload) recreated the pane on each save → now keyed by `task.file`; (b) the daily watcher reloaded the focused day after our own debounced save → now only reloads when on-disk content actually differs.
- **Dangling backlink looked broken:** `[[ashdlsa]]` "wouldn't open" because no page with that title existed — now clicking creates it. The earlier `↗`-only open was also non-obvious; clicking the link itself now opens.
- **Don't `git add -A`:** the working tree carries unrelated in-progress work (a "Changes tab" git-diff viewer, `TerminalPanel`, regenerated html). Commits here stage only the specific feature files.

## What to remember
- The bullet model: `OutlinerView` renders `BulletRendered` (a `Button`) when a row isn't focused and `BulletRow` (NSTextField) when it is. Don't reintroduce `Text` `.link` taps.
- `LoreTasksView.reload()` is the heavy path (reads all task files + rebuilds the whole lore graph); per-edit saves must use `updateInPlace` + the off-main `scheduleGraphRefresh`, not `reload()`.
- `LoreTaskItem.id` is a fresh UUID each load — never key views by it across reloads; use `file`.
- Backlink resolution searches `LoreLinkIndex.allDirs` (decisions/ideas/notes/kpis/overview/tasks) by frontmatter `title`; `devlog` isn't in that set.
- Still legacy-only: the "Dev Dash" task source uses the modal `TaskDetailSheet`; the right-pane outliner experience is the **Lore** source (toggle at the top of Tasks), which still defaults to "devdash".

---

## Commits
- 06ebefb tasks: lore task detail pane edits body as inline bullet outliner (autofocus + autosave)
- 4ca7a90 tasks: inline quick-add (type title + Enter creates task and opens it for editing)
- a2954df tasks: editable title in detail pane; key pane by file so autosave doesn't drop focus
- 44674a8 perf: task edits update one task in place + off-main graph rebuild; outliner avoids O(n^2) per-row flatten
- 88d588a add delete: trash button (with confirm) in task detail pane and page doc pane
- 5501569 tasks: ⌫ deletes the selected task (with confirm)
- ed4a079 daily: make backlink doc panel editable (type into body, debounce-save, preserve frontmatter)
- 1af7443 daily: Typora-style live markdown editor in doc pane (later retired)
- 81b3c7d daily: richer markdown rendering (links/lists/blockquote; bold/italic/code in bullets)
- de76343 daily: docs are bullet outliners too (unify on outliner; drop H1 + retire MarkdownLiveEditor)
- 637bba5 daily: open a page straight into edit mode (autofocus first bullet; never write on open)
- 8a971d1 / 77019c2 / b8917d7 / 2526288 daily: bullet tap/edit/link iterations (settled on Button-based)
- fed0246 daily: clicking a backlink to a missing page creates the note and opens it (Roam-style)
- 8eede1a daily: clicking a [[page]] link opens it; pencil affordance edits the bullet
- a79e267 daily: Claude sessions band expanded by default (collapsible per day)
