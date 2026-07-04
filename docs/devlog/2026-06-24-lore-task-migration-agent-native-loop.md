---
type: devlog
title: "Day 7 — retire .devdash/tasks.json for lore; build the agent-native task loop"
date: "2026-06-24"
day: 7
phase: Tooling
---

**Made lore the single source of truth for tasks, then built the full agent-native loop: launch a task into Claude, Claude acts through `lore` (status, PR-review task, artifacts), and dev-dash reloads live, renders, and notifies — all verified round-tripping end-to-end.**

## What got done

- **Lore-adapter `TaskStore`** (ADR 0006) — reimplemented `TaskStore` over `docs/tasks/*.md` (numeric ids) instead of `.devdash/tasks.json`, preserving the public API so the ~30 call sites and the AI integration are unchanged. `.devdash/tasks.json` migrates once on first read (`TaskLoreMigrator`) then renames to `.migrated`. Hardened against quote/backslash corruption, comma-in-phase splits, `## Status history` truncation (sentinel-delimited now), unknown-key loss (devdash_id/pr preserved), and non-zero-padded ids — all locked down by a new `--selftest-taskstore` (44 checks; no importable test target for the app).
- **Launch with Claude** (ADR 0005) — a task action that opens an interactive `claude` in the project's embedded terminal, seeded with the task spec + the `lore` commands to report back.
- **Action surface is `lore`** — Claude updates dev-dash by running `lore set-status` / `lore add task --field pr=<url>` / `lore add artifact --field task=<id>`. No new CLI; one write path; status history stays consistent.
- **PR card** — `TaskItem` gains a first-class `pr` field; TaskDetailSheet renders a live `gh`-backed PR card; rows show a `#N` badge.
- **Artifacts** — a lore `artifact` doc type; `ArtifactStore` reads them; TaskDetailSheet renders a task's artifacts (markdown body or referenced binary).
- **Live sync + notifications** — a `NotesFileWatcher` over `docs/tasks` + `docs/artifacts` reloads live; native notifications fire on new PR task, task→done, new artifact, and meaningful session end. Anti-spam by explicit startup snapshot seeding + per-mutation snapshot refresh.
- **LoreTasksView is primary** — `taskSource` defaults to lore; Dev Dash kept as legacy; AI actions (Launch/Run) wired in via numeric-id bridges; status/owner mutations route through `TaskStore`.
- **lore tooling** (merged to lore main) — added the `artifact` type; fixed `writeDoc` to `mkdir` a new type's dir; fixed `set-status` to INSERT a `status:` frontmatter key when absent (it previously only replaced).

## Decisions

- **lore as source of truth, `TaskStore` as a lore adapter** — the AI integration was built on `TaskStore`/`TaskItem`, so swapping the storage backend (not the API) was the lowest-risk path and kept the integration intact. No runtime UUID↔numeric map needed; the remap runs once at migration.
- **`lore` over a new `devdash` CLI** — an earlier draft proposed a `devdash` CLI; it duplicated `lore add`/`set-status`. Routing Claude's writes through lore means one write path that matches the human/UI path exactly.
- **Explicit launch over ambient context injection** — ambient per-prompt injection of project state was deprioritized (mostly redundant with Claude reading the repo); the high-signal move is seeding the *task* once, at launch.

## Issues

- **The loop is the test.** Component checks passed, but exercising the genuine end-to-end path caught what isolation missed every time: a stale pre-migration app instance answering on the port (mis-read as a data bug), lore not creating a new type's dir, and `lore set-status` silently not persisting into frontmatter. None broke a build.
- **`--fields` vs `--field`** — lore's `parseFlags` only accepts repeated `--field k=v`; `--fields` is silently ignored. The seeded launch prompt and ADR used the wrong form; fixed.
- **Adversarial review on the data layer** caught a chain of silent corruptors (unknown-key loss → duplicate tasks, escaping not reversed, notes truncation, comma-in-phase) before any of it touched real data — and before relaunching, which would have run the buggy migrator across every project.

## Verified

- `--selftest-taskstore` 44/44; end-to-end round-trip in a temp project: `lore add task` / `lore set-status task X done` / `lore add task --field pr=<url>` / `lore add artifact --field task=X` all read back correctly through dev-dash's `TaskStore`/`ArtifactStore` (status → `[done]`, pr field present, artifact linked).
