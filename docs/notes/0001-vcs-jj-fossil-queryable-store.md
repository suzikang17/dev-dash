---
type: note
title: "Research: jj, Fossil & the queryable project store — and how dev-dash + lore already build the bridge"
tags: research, version-control, architecture, jj, fossil
created: 2026-06-30
---

External research into "what replaces git" and how it maps onto this project's
architecture. Rendered HTML brief: `docs/research/vcs-and-queryable-project-store.html`
(self-contained, offline — same pattern as ticket
[[0007-export-a-projects-devlog-as-a-shareable-html-report]]).

## The two bets

- **Jujutsu (jj)** — git's model is right, its UX is wrong. A new frontend on git's
  object store (a jj repo *is* a git repo). Wins: no staging (working copy is a
  commit), **total undo via the operation log** (`jj op restore`), conflicts stored as
  data, `jj workspace` (worktrees that share one op log — docs cite "give AI agents
  their own sandbox"). Adoption risk ≈ 0 because it stays git.
- **Fossil** — version control shouldn't be standalone. One SQLite file bundling VCS +
  issues + wiki + forum + UI. Faithful, never-rewrite history. But **not git-compatible**
  → leaves the ecosystem.

## Fossil's breadth — the gaps

Wide, fixed, pre-AI scope: no code review / PR workflow, no CI/CD, one-way git interop
only, fixed artifact types, **not agent-native** (no schema-as-prompt, no `owner: ai`, no
injected policies), no operation log / undo, no real-time hook stream. These gaps are
almost exactly what lore + dev-dash add on top of git.

## The bridge — and we've built ~80% of it

The conceptual synthesis is a project as an *event-sourced, queryable, branchable store*.
Mapping it to what exists here:

| Element | Whose idea | Status |
| --- | --- | --- |
| Queryable knowledge as data | Fossil's vision | ✓ lore typed docs |
| …on git, not a DB | jj's bet | ✓ git = time machine |
| Graph over records | both | ✓ `LoreLinkIndex` |
| Branchable agent sandboxes | jj workspaces | ✓ `WorktreeManager` |
| Unified operation log | jj op-log | ◑ four partial seams |
| Safe undo / time-travel | jj `op restore` | ✗ missing |

lore made **jj's substrate bet with Fossil's ambition** — git-native markdown, not a
SQLite blob. See [[0006-retire-devdash-task-store-for-lore]] (lore as source of truth)
and [[0004-claude-code-hook-event-bus]] (the live agent op-log).

## The event-log / current-state split is already explicit

[[0012-agent-native-policy-lore-type]] draws the exact line the synthesis turns on:
an **ADR is decision history** (immutable), a **policy doc is a living operating
instruction** (mutable current-state). That, plus [[0010-tickets-contain-tasks]], is the
append-only-record vs current-state separation as first-class doc types — and the
injected `policy` type is the agent-native capability Fossil can't match.

## The gap & the recommendation

Four append-only streams exist (status history, hook bus, session JSONL, devlogs) but the
richest — the hook event bus — is in-memory, 300-capped, never persisted, and there's no
general undo/time-travel.

1. **Persist the hook event bus** → append-only per-project NDJSON. Lowest-hanging; you
   already produce the stream. *Commit to this.*
2. **Unify the durable seams** into one timeline keyed by task/cwd — the "SELECT across
   code + knowledge + activity, as-of any point" surface.
3. **Spike jj behind `launchInWorktree`** — swap `WorktreeManager.create` for
   `jj workspace add` on one project. *Evaluate, don't migrate.* Note:
   `GitStatusScanner.parseWorktrees` needs a `jj workspace list` variant (jj workspaces
   aren't git worktrees). jj covers the **code half** of undo; the unified event log
   covers the **knowledge/external half** jj can't touch.
