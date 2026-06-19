# Design: Auto-synthesized project one-pager

**Date:** 2026-06-19
**Status:** Approved (design) — pending implementation plan

## Problem

We want a one-pager per project: a high-level overview of the app, its product
docs, and — most importantly — its *current status* (where things stand right
now). Today that "current status" has no home: it either lives in someone's head
or goes stale the moment it's written down.

## Context: how this fits the lore engine

The repo already has two layers that overlap with this idea:

- **lore** (`docs/devlog/`, `docs/decisions/`, `docs/ideas/`, `docs/tasks/`) —
  the *capture* layer. Append-only, schema'd markdown, indexed by the `lore`
  CLI. The time-series record of what happened.
- **The Product "living document"** (`docs/devdash/`, via `ProductDocGenerator`)
  — the *curated surface* layer. Already renders a tabbed page:
  Overview · Roadmap · Initiatives · Goals & KPIs · Ideas · PRDs ·
  Status Reports · Docs. Some tabs are hand-authored HTML, some are generated
  from tasks.

**The fit:** the one-pager does **not** extend lore — it *reads from* it. lore
stays the source of truth (devlogs, decisions, ideas, tasks); the one-pager is a
read-only **projection** over lore + git + tasks. That separation keeps both
clean: lore is human-authored capture, the one-pager is a derived view.

The "current status" block is auto-synthesized and **deterministic** (no AI
call): always current, zero upkeep. A written snapshot would be stale the instant
it's saved, so we deliberately do **not** introduce a new `status` lore type or
auto-write lore docs.

## Goals

- A per-project status snapshot, synthesized from existing data, always current.
- Surfaced as part of the Product tab so the page reads as a true one-pager.
- Modeled so a future cross-project roll-up is a trivial aggregation.

## Non-goals (YAGNI)

- No AI summarization (deterministic only).
- No new lore type; no writing to lore.
- The native cross-project board is **designed** here but **not built** in
  phase 1 — we ship per-project first, confirm the field set, then build it.

## Architecture

One idea: a plain value type, `ProjectStatus`, synthesized once from data the
store already holds plus two small lore reads. Everything else renders that
value. One synthesizer, two consumers (HTML now, native board later).

## Components

1. **`ProjectStatus`** — a `Codable` struct. Pure data, no logic.
   Fields:
   - `projectName: String`
   - `tagline: String?` — from project meta if present, else framework/stack
   - `lastSession: LoreRef?` — latest devlog
   - `activeTaskCount: Int`
   - `blockedTaskCount: Int`
   - `recentDecision: LoreRef?` — latest ADR
   - `commits7d: Int`
   - `runningPorts: [Int]`
   - `health: HealthStatus`
   - `generatedAt: Date`

   `LoreRef` is a small nested `Codable` struct (`{ title: String, date: Date? }`)
   rather than a tuple — Swift tuples aren't `Codable`, and `ProjectStatus` is
   persisted/serialized for the phase-2 board.

2. **`LoreReader`** *(new, small scanner)* — `latest(type:in:) -> LoreEntry?`,
   reads the newest file in `docs/<type>/` via frontmatter (title + date). This
   logic is currently inlined in `DailyTabView.reload()`; extract it so both the
   synthesizer and (eventually) DailyTabView can share it. Best-effort: a missing
   directory returns `nil`, never throws.

3. **`ProjectStatusSynthesizer`** — `synthesize(inputs) -> ProjectStatus`.
   A **pure function** of its inputs (tasks, heatmap, services, health) plus the
   lore reads. Deterministic, never throws. Absent data degrades to empty/`nil`
   fields (rendered as "—"). Unit-testable with fixture inputs.

4. **HTML renderer (phase 1)** — `ProductDocGenerator` gains a generated
   `sections/status.html`, rendered at the **top of the Overview tab** so the
   Product tab reads top-to-bottom as a one-pager: *snapshot → overview →
   roadmap → docs*. Regenerated on the existing `regen()` (tab open / project
   switch / manual refresh) so it stays current with no upkeep.

5. **Native roll-up (phase 2, designed not built)** — `StatusBoardView` on Home
   renders `[ProjectStatus]` = `projects.map(synthesize)`, each row clickable
   into the project.

## Data flow

The store already loads tasks / heatmaps / services / health on each refresh. We
add `store.projectStatus(for:) -> ProjectStatus`, which gathers those inputs and
calls the synthesizer.

- **Phase 1:** `ProductTabView.regen()` calls `store.projectStatus(for:)` →
  renders `sections/status.html` → included in the index HTML.
- **Phase 2:** the same call across all projects feeds `StatusBoardView`.

`commits7d` comes from the commit heatmap's daily buckets (fallback:
`recentCommits` filtered by date).

## Naming / coexistence

The living doc already has a **"Status Reports"** tab = hand-written weekly
snapshots (a user folder). The new block is a generated, always-current
**"Snapshot."** They coexist with no collision: Snapshot = auto/derived,
Status Reports = manual/narrative.

## Error handling

Synthesis never fails. Missing lore (no devlogs/decisions yet), no running
servers, or no commits all degrade gracefully to empty/`nil` fields shown as
"—". Lore reads are best-effort and swallow IO errors.

## Testing

- `ProjectStatusSynthesizer` — pure; fixture inputs → assert each field.
- `LoreReader` — temp directory with sample frontmatter files → assert latest.
- HTML render — assert the key fields (last session, task counts, ports,
  health) appear in the generated markup.

## Resolved open choices

- **Placement:** top-of-Overview (true one-pager). Trivial to switch to its own
  first tab later if desired.
- **`tagline` source:** project meta if present, else framework/stack. Used
  mainly by the phase-2 board.

## Phasing summary

- **Phase 1 (this spec → plan):** `ProjectStatus` + `LoreReader` +
  `ProjectStatusSynthesizer` + `store.projectStatus(for:)` + the HTML status
  block in the living doc, with tests.
- **Phase 2 (later):** `StatusBoardView` cross-project roll-up on Home, reusing
  the same synthesizer.
