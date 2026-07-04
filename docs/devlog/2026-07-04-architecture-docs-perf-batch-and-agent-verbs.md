---
lore_type: devlog
created: 2026-07-04
title: "Architecture docs, perf batch, and ⌘K agent verbs"
date: 2026-07-04
day: 17
---

**Surveyed the whole codebase (two parallel Explore agents), rewrote CLAUDE.md + added docs/ARCHITECTURE.md, then landed a 10-item batch: the `>-` title-corruption fix, six perf fixes from the audit, a second policy, batch draft breakdown, and ⌘K agent verbs.**

## What got done
- **Architecture docs**: rewrote `CLAUDE.md` for the current app (stores, agent-native model, self-test flags, perf guardrails) and added `docs/ARCHITECTURE.md` (full structural map from a two-agent survey: architecture mapper + performance auditor).
- **`>-` title corruption fixed at the root**: `TaskStore.parseTaskFrontmatter` now parses YAML block scalars (`>-`, `>`, `|`, …) — the lore CLI writes long titles as folded scalars and the line-based parser read the literal `>-`. Also stopped continuation lines being misread as phantom keys. 8 new self-test checks. Tasks 0001–0006 render real titles again; ticket 0004 got its missing `status:`.
- **Perf batch** (from the audit, ranked by impact):
  - `gitStatuses` collected and merged in ONE `@Published` write per refresh tick (was N writes × ~64-publisher fan-out).
  - Living-doc generation (`ProductDocGenerator.generate`) off the main actor with a stale-completion guard.
  - `NotesFileWatcher` now reports *which* dirs changed; the store reloads only affected projects (was: any doc write re-parsed every project). Also fixed a debounce race (event handlers mutated the work item from the global queue).
  - Daily tab: digest arrivals recompose day groups from a cached docs scan — no more full docs-tree rescan per digest.
  - `LoreTasksView`: filter cascade memoized into a rebuilt-on-change `TaskIndex` (was up to 9 re-filters per render + O(tickets×tasks) flat list per keystroke).
  - Auto-refresh skips ticks while the app is inactive (didBecomeActive fires a catch-up); static `dayFormatter` in the per-file `loadTask` loop.
- **Policy 0002 (commit conventions)**: `applies_to: project`, injected into every task launch alongside ticket policies via a new generic `policyText(projectPath:appliesTo:trigger:)`.
- **Batch breakdown**: "Break down drafts (N)" button in the tickets toolbar — sequential suggestion runs, per-ticket inline review, nothing auto-written.
- **⌘K agent verbs**: break down ticket / launch with Claude / mark done, matched by title in the current project. Breakdown bridges to LoreTasksView's checklist via `store.pendingBreakdownTicketId`.

## Decisions
- Frontmatter block-scalar support went into the **parser**, not a file rewrite — new lore-CLI writes would have recreated the corruption.
- Refresh pause is **skip-tick + catch-up-on-activate**, not timer teardown — simplest correct shape.
- ⌘K → view-state bridge is a consumed-once `@Published` field rather than moving checklist state into the store.

## Issues
- The perf auditor flagged the exact granularity problem the ServerStore split had previously addressed: the remaining hot per-project dicts still fan out on every write. Batching (gitStatuses) was the cheap fix; peeling a child store off `DashboardStore` (3.5k lines, ~64 publishers) remains open pressure.
- `git log --since=today` was empty at devlog time — the sitting straddled midnight, commits are dated 2026-07-03.

## What to remember
- Perf guardrails now live in CLAUDE.md — main-thread I/O, per-key `@Published` writes, full rescans, body-time filtering, per-loop formatter allocs are the recurring lag patterns.
- `LoreTasksView` mutations of `tasks` MUST call `rebuildIndex()` (funnel: `reload`, `updateInPlace`) or the list goes stale.
- Deferred/still open: incremental `LoreLinkIndex` (full two-pass walk per edit), sharing the two per-project git subprocesses per tick, and the DashboardStore child-store split.

---

## Commits
- 2e6f3d7 docs: rewrite CLAUDE.md for current architecture; add docs/ARCHITECTURE.md
- 705a302 fix: parse YAML block-scalar frontmatter (lore CLI folded titles showed as '>-')
- d97b097 perf: batch gitStatuses into one @Published write per refresh tick
- 1c04016 perf: run living-doc generation off the main actor
- 2c42cbd perf: watcher reloads only changed projects; fix debounce race in NotesFileWatcher
- 2f4c5c7 perf: digest updates recompose Daily view from cache instead of full docs rescan
- ea2deb3 perf: memoize LoreTasksView filtering into a rebuilt-on-change index
- c77b161 perf: pause auto-refresh while app inactive; static day formatter in loadTask
- 5aa4dd3 feat: commit-conventions policy (0002) + project-scoped on_work injection
- af37639 feat: batch 'break down drafts' action in tickets toolbar
- ee783e7 feat: command-bar agent verbs — break down ticket, launch with Claude, mark done
