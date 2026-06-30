---
lore_type: decision
title: "Durable agent operation log: persist the hook bus, anchor lore docs to jj change-ids"
date: 2026-06-30
category: architecture
revisit: true
---

## Why this choice

The hook event bus ([[0004-claude-code-hook-event-bus]]) makes any Claude session an
event source, but `DashboardStore.recentEvents` is **in-memory, 300-capped, and never
persisted** — the operation log evaporates when the app quits. Four append-only seams
exist today (per-task `## Status history`, the hook bus, the session JSONL transcripts,
dated devlogs), but there is no *unified, durable, rewindable* record and no general
undo / time-travel.

We want to inspect and rewind "what an agent did" across **both** code and knowledge.
jj's operation log covers the code/repo half; we still need to capture the
knowledge/external half ourselves.

## Decision

1. **Persist the hook bus as append-only NDJSON** — one JSON object per line, per
   project, at `<repo>/.devdash/events/<YYYY-MM-DD>.ndjson` (`.devdash/` is already
   gitignored). NDJSON is the **source of truth**: crash-safe O(1) append (`seekToEnd`,
   never read-modify-write), and it mirrors the Claude session `.jsonl` format already
   in the system. Write in `DashboardStore.handleHookEvent` — where raw `cwd` is matched
   to a known `projectPath` — off the main thread. Events with no matched project go to
   `~/.devdash/events/_unmatched.ndjson`. `recentEvents` (300-cap) becomes a tail view.

2. **Codable mirror, not the view struct.** `ClaudeIntegrationEvent` isn't `Codable`,
   and its `id`/`timestamp` are construction-time. Add a `PersistedEvent`
   (`ts` ISO-8601, stable `id`, `session`, `cwd`, `hook`, `cat`, `detail`) and, when jj
   is present, the contemporaneous **jj op id**.

3. **The query view is regenerable, not the truth.** When the unified "SELECT across,
   as-of any point" surface needs indexes, build a SQLite view via the system
   `import SQLite3` (no SPM dependency — honors the *no external Swift dependencies*
   rule), rebuilt by replaying the NDJSON. Until then, an in-memory load suffices.

4. **jj anchoring in lore (not raw ops).** With jj, lore docs reference stable
   change-ids / op-ids instead of storing operations: `task.change_id`,
   `artifact.jj_op`/`change_id`, and the SessionEnd devlog embeds `jj op restore <id>`.
   The firehose stays in jj's op-log + the NDJSON; **lore stays the curated index that
   points into them.** jj change-ids are stable across rebases (unlike git shas), so the
   task→code link survives history rewriting.

5. **Consumption.** *Push* — `handleHookEvent` on SessionStart injects a queried slice of
   the log via `buildInjectedContext`. *Pull* — expose a `devdash events` CLI/MCP tool,
   advertised the agent-native way ([[0012-agent-native-policy-lore-type]]) via a
   `policy` doc (`applies_to: session`, `trigger: on_start`).

## Alternatives considered

- **SQLite as the store** (Fossil's bet) — rejected as the *truth* (binary, not
  diffable, only-copy fragility); adopted as a regenerable *view* instead.
- **One growing JSON array** — rejected; read-modify-write, not crash-safe.
- **Global `~/.devdash/events/` keyed by path** — rejected as primary; breaks the
  "state about a project lives in the project" precedent (`project.json`, `recap.json`).
  Kept only as the `_unmatched` fallback.
- **Storing raw operations in lore docs** — rejected; high-frequency machine data bloats
  the repo and breaks lore's source-vs-regenerable-view cleanliness.

## Boundary

jj manages its own op-log autonomously — no wiring. The only bridge code is **stamping
events with the live jj op id**. Undo = `jj op restore <id>` (code half) + replay /
compensate the NDJSON for external effects like an opened PR or a Linear move.

## Relationship to ADR 0012

jj op-log + `artifact`/`devlog` = immutable history; `task`/`policy` = living
current-state; the change-id is the join. See
[[0012-agent-native-policy-lore-type]]. Work tracked under ticket 0008.
