---
lore_type: decision
title: "Retire the .devdash/tasks.json task store; make lore docs the single source of truth"
date: 2026-06-24
category: architecture
revisit: false
---

## Why this choice

Designing agent-native task actions ([[0005-agent-native-task-actions]]) surfaced a
blocking contradiction: dev-dash has **two task systems**. The live store the UI reads
and edits is `.devdash/tasks.json` (`TaskStore`, UUID ids); lore `docs/tasks/*.md`
(numeric ids) is only a **one-way export** (`TaskLoreMigrator`). So Claude acting
through `lore` (`lore add` / `lore set-status`) would write the export, which dev-dash
never reads — the agent-native loop can't close. We are retiring the
`.devdash/tasks.json` store and making lore docs the single source of truth.

## Decision

Make **`TaskStore` a lore adapter**: keep its public API (`read`, `add`, `setStatus`,
`setOwner`, `setHasAIRun`, `setParent`, `setPhases`, `addCompletedPhase`, `delete`,
`hasChildren`, `update`, `write`) and the `TaskItem` model, but swap the backend from
`.devdash/tasks.json` to `docs/tasks/*.md`. `TaskItem.id` becomes the lore numeric id
(filename prefix). The ~30 call sites and the whole AI integration keep working
unchanged; only the storage changes.

- **Field mapping** is already defined by `TaskLoreMigrator` (title, status, owner,
  category, source, created/started/completed, ai_run, phases, completedPhases, stage,
  persona, linkedDoc, parent, ghIssue → frontmatter; notes → body). All enum raw values
  already match lore conventions.
- **No runtime id map needed.** Once `TaskStore` returns numeric ids, `linkedTaskId`,
  `openTaskId`, and `parentId` are all numeric uniformly. The UUID→numeric remap runs
  **once**, at migration, via `TaskLoreMigrator` (which also remaps parents).
- **Migration**: on load, if `.devdash/tasks.json` exists and isn't yet exported,
  run `TaskLoreMigrator` (idempotent via `devdash_id`), then read from lore thereafter.
  Leave the old json in place (don't delete user data) but stop writing it.
- **One UI**: consolidate on a single task view; remove the `AppStorage("taskSource")`
  toggle. (Which view survives — see open decision below.)
- **Closes the loop**: `lore add`/`lore set-status` now write the same files dev-dash
  reads; `NotesFileWatcher` already refreshes on change. The Stage-1 launch's
  report-back commands become correct once ids are numeric.

## Options considered

- **Lore-adapter `TaskStore` (chosen)** — preserves the AI integration + all call sites;
  smallest blast radius — vs. **consolidate onto `LoreTasksView`** (rewire the entire AI
  integration to `LoreTaskItem`; larger, riskier) vs. **two-way json↔lore sync**
  (fragile, conflict-prone — rejected).
- **Id type:** numeric lore id everywhere (chosen) vs. keep UUIDs with a persistent map
  (extra state, no benefit once json is gone).
- **Task UI (decided):** `LoreTasksView` becomes the **primary** task view and hosts the
  AI integration (Launch with Claude, run, SessionEnd advance); `TasksTabView` is
  **retained as a legacy/alternate view**. Both render lore-sourced tasks (via the
  lore-backed `TaskStore` / `projectTasks`), so there is one source of truth with two
  presentations. The AI integration stays on the store methods (which now operate on
  lore); LoreTasksView gains the action affordances and bridges its rows to the numeric
  lore id.

## Tradeoffs

- Gain: one source of truth; agent-native loop closes; AI integration preserved; lore
  becomes the durable, git-tracked, `lore`-CLI-addressable task store.
- Give up: `TaskItem.id` semantics change (numeric); cascade-delete must be
  reimplemented over lore `parent:` frontmatter; status history now lives in the doc
  body (lore convention) alongside the date frontmatter; existing users' tasks go
  through a one-time migration.
- Risks: anything that persisted a task UUID across launches (none found beyond
  in-memory `linkedTaskId`/`openTaskId`, which are transient) would need attention;
  validated during migration.

## Build stages

1. Lore-adapter `TaskStore` — reimplement internals over `docs/tasks/*.md` (numeric
   ids, full field mapping, status history + dates, cascade delete via `parent:`),
   preserving the API. Unit-verify against the existing call sites.
2. Migration + flip — on load, migrate `.devdash/tasks.json` → lore once
   (`TaskLoreMigrator`), then read lore; stop writing json.
3. UI — make `LoreTasksView` primary and wire the AI integration (Launch/run/advance)
   into it, bridging its rows to the numeric lore id; keep `TasksTabView` as a legacy
   view; both read lore-sourced tasks.
4. Fix Stage-1 launch — interpolate the numeric lore id into the `lore` report-back
   commands; resume [[0005-agent-native-task-actions]] (PR card, artifacts,
   notifications).
