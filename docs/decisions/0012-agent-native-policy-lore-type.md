---
lore_type: decision
title: "Agent-native policies: a `policy` lore type the app injects into agent prompts"
date: 2026-06-27
category: architecture
revisit: true
---

## Why this choice

We wanted Claude to break a ticket into tasks "when appropriate" ([[0010-tickets-contain-tasks]]).
The question was *where the instruction for that behavior should live* so the agent
actually reads and acts on it. Three homes were considered:

- **Lore schema `prompt:` field** — exists (e.g. the `task` type has one), but it is
  scoped to "author THIS one doc's body when created via `lore add`". Breaking a ticket
  into *separate* task docs is a cross-document action — wrong scope. And dev-dash
  creates tickets in Swift (`TicketStore.ticketDoc`), bypassing `lore add`, so a schema
  `prompt:` never fires for app-created tickets anyway.
- **Project `CLAUDE.md` prose** — auto-loaded by every `claude -p` session, but it is
  advisory (the agent may ignore it) and mixes behavior policy into the conventions file.
- **A dedicated `policy` lore type the app injects** (chosen) — keeps the behavior as
  *data* in lore, lets the app inject it deterministically into the exact prompts it
  builds, and makes the frontmatter do real routing work.

## Decision (chosen: `policy` lore type + app-side prompt injection)

- **New lore `policy` type** (`docs/policies/*.md`). Frontmatter is *routing metadata*:
  `applies_to` (scopes: ticket/task/project/pr/release/session/any), `trigger`
  (on_demand/on_work/always wired now; on_start/before_done/before_merge/on_session_end/
  on_release/scheduled declarable for later), `status` (draft/active/deprecated — only
  `active` is injected), and optional `priority` (lower = injected first).
- **Frontmatter format**: `lore` has no `list`/`int` field type, so multi-value fields
  (`applies_to`, `trigger`) are **comma-separated strings** (`applies_to: ticket, task`),
  matching the existing `task` schema `phases`/`completedPhases` convention. The app's
  `PolicyStore.parseList` splits on commas (and tolerates a bare scalar or legacy
  `[a, b]` brackets). This is *why* the schema uses `type: string`, not a list type.
- **App is the executor**: `PolicyStore` reads policy docs; `DashboardStore.policies(for:
  appliesTo:trigger:)` returns active, scope+trigger-matched policies ordered by
  `(priority, id)`. The breakdown feature injects the matched policy **bodies** into
  (a) the on-demand `suggestTasksForTicket` run and (b) the `launchClaudeForTicket`
  seed prompt (`on_work`, gated on `task.ticket`). Editing a policy doc changes agent
  behavior with no code change.
- **First policy**: `0001-ticket-breakdown.md` (`applies_to: ticket`,
  `trigger: on_demand, on_work`, `status: active`).

## Why `applies_to`/`trigger` are open (comma) lists, not closed enums

Stress-testing ~16 candidate policies (commit conventions, verification, status hygiene,
roadmap upkeep, idea→task promotion, PR review, release security, …) showed a closed
enum for `applies_to`/`trigger` would need a schema edit every time a new scope or
trigger is invented, and that some policies are multi-scope/multi-trigger. Open
comma-lists + a `status` enum (not a bool) survive all of them without migration.

## Policy docs vs ADRs

An **ADR is decision history** (immutable: why we chose this). A **policy doc is a living
operating instruction** the agent follows now (editable; deprecated when superseded).
Don't conflate them. This ADR records the *decision* to add the type; the policies
themselves live in `docs/policies/`.

## Scope / follow-ups

Mechanism ships with one real policy. Deferred: migrating commit/verification/etc. prose
into policies; wiring non-core triggers; sub-document `match:` filtering (encode such
conditions in policy prose for now); a batch "decompose all draft tickets" sweep.
Spec: `docs/superpowers/specs/2026-06-27-ticket-breakdown-policy-design.md`.
