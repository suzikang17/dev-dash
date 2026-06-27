# Design: Agent-native policies + ticket breakdown

**Date:** 2026-06-27
**Status:** approved (design)
**Related:** ADR 0010 (tickets contain tasks), the new "draft" empty-ticket state

## Goal

Let users break a ticket into child tasks on demand, with Claude suggesting the
tasks and the user reviewing before anything is written. Do it in a way that is
**agent-native**: the *policy* for how/when to break down lives in a lore doc,
and the app reads that doc and injects it into the prompt — so behavior is
editable as data, not hardcoded in Swift.

This introduces a reusable **`policy` lore type** as the single source of truth
for agent behavior, with ticket breakdown as its first real instance.

## Background — what already exists

- `DashboardStore.suggestTasksForStage` (DashboardStore.swift:2719) already
  builds a task-suggestion prompt and runs `claude -p` via
  `runClaude(..., kind: .taskSuggestion)`. It is **dead code — zero callers.**
- `DashboardStore.parseSuggestedTasks(from:projectPath:)` (2801) parses
  `TASK: <title>` lines out of a run's output. Also **dead code.**
- `DashboardStore.launchClaudeForTicket` (2233) seeds a work task + launches
  Claude on a ticket. The app builds this prompt, so it can inject policy text.
- `DashboardStore.addTask(projectPath:title:…:ticket:)` (1820) creates a child
  task linked to a ticket.
- Tickets are created in Swift (`TicketStore.ticketDoc`), **bypassing `lore add`
  and the lore schema `prompt:`** — so doc-type schema prompts never fire for
  app-created tickets. This is *why* the policy must be injected by the app, not
  carried in the lore schema.
- The empty-ticket **"draft"** state (just shipped) is the visible "not yet
  broken down" signal. `ticketRollupStatus` derives status from child tasks; a
  ticket with ≥1 task is "decomposed."

## The `policy` lore type

New lore type whose **frontmatter is routing metadata** the app uses to decide
which policy to inject, when. Stress-tested against ~16 candidate policies; the
key lesson was that `applies_to`/`trigger` must be **open lists**, not closed
enums, and activation needs a `status` enum (not a bool).

### Schema — `docs/.lore/types/policy.schema.yaml`

```yaml
name: policy
dir: policies
heading: Policies
id: { strategy: sequential, pad: 4 }
body: free
groupBy: { field: status, order: [active, draft, deprecated] }
frontmatter:
  - { name: title,      type: string,  required: true }
  - { name: applies_to, type: list,    required: true }   # lore types or scopes: ticket, task, project, pr, release, session, any
  - { name: trigger,    type: list }                       # core wired now: on_demand, on_work, always; others declarable-but-not-enforced
  - { name: status,     type: enum, values: [draft, active, deprecated], required: true }
  - { name: priority,   type: int }                        # optional; lower = injected first
index:
  - { header: "#", source: id }
  - { header: Policy, source: title, link: true }
  - { header: Applies to, source: applies_to }
  - { header: Trigger, source: trigger }
  - { header: Status, source: status }
```

### Field semantics

- **`applies_to`** — open list of scope strings. App matching is membership:
  a policy matches a context if `applies_to` contains that scope (or `any`).
  Validated loosely (any string allowed); no schema change to add a scope.
- **`trigger`** — open list. Only `on_demand`, `on_work`, `always` are *wired*
  in this spec. Others (`on_start`, `before_done`, `before_merge`,
  `on_session_end`, `on_release`, `scheduled`) are declarable for future
  policies but are not consumed by any code yet.
- **`status`** — only `active` policies are injected. `draft` = authored but not
  enforced; `deprecated` = superseded, kept for history.
- **`priority`** — optional ordering when multiple policies match one context.
  Lower injected first. Absent = sorts after any with an explicit priority,
  then by id.

### First policy doc — `docs/policies/0001-ticket-breakdown.md`

```markdown
---
lore_type: policy
title: Break tickets into tasks
applies_to: [ticket]
trigger: [on_demand, on_work]
status: active
---
Break a ticket into child tasks when it implies more than one distinct
deliverable, can't be finished in a single focused sitting, or spans multiple
files or stages. Don't break down a ticket that is already a single concrete
unit of work.

Produce 3–6 tasks. Each must be specific to *this* ticket — not generic
best-practice boilerplate. Don't duplicate tasks the ticket already has.

Output each task on its own line as exactly: `TASK: <title>`
```

## App: PolicyStore + query

New `Sources/DevDash/Scanners/PolicyStore.swift`, mirroring `TicketStore`'s
lore-adapter pattern (same frontmatter helpers, numeric-id tolerance, `read`).

- `struct Policy { id, title, appliesTo: [String], trigger: [String], status, priority: Int?, body }`
- `static func read(_ projectPath:) -> [Policy]` — scans `docs/policies/*.md`.
- Store helper on `DashboardStore`:
  `policies(for projectPath: String, appliesTo scope: String, trigger: String) -> [Policy]`
  → filters `status == .active`, `appliesTo contains scope || contains "any"`,
  `trigger contains trigger`, sorted by `(priority ?? .max, id)`. Returns the
  matched policies' **bodies** for prompt injection.

The store loads policies into a `@Published var projectPolicies` on project scan
(same lifecycle as `projectTickets`).

## Feature 1 — in-app ticket breakdown (on-demand + review)

### Trigger UI
Ticket header context menu (`LoreTasksView.ticketHeader`) gains a section:
- **"Break into tasks"** — Quick mode (metadata-only `claude -p`, seconds).
- **"Break into tasks (read code)"** — Deep mode (read-only repo-aware run).

Shown on all tickets; most useful on draft tickets.

### Generation
New `DashboardStore.suggestTasksForTicket(ticketId:projectPath:deep:)`, modeled
on the dead `suggestTasksForStage`. Prompt is assembled from:
- injected **policy bodies** from `policies(appliesTo: "ticket", trigger: "on_demand")`,
- ticket **title, notes, category**,
- existing child task titles (to avoid duplicates).
- **Launch-template is intentionally NOT included.**

Quick: `runClaude(allowEdits: false, kind: .taskSuggestion)`.
Deep: same but the prompt explicitly invites reading relevant code first; still
`allowEdits: false`.

### Review (inline checklist)
When a run for ticket *X* completes, its `TASK:` lines are parsed via the
existing `parseSuggestedTasks` into a per-ticket suggestion list held in view
state (e.g. `@State suggestionsByTicket: [String: [SuggestedTaskDraft]]`).

The expanded ticket body renders the checklist (the approved mockup):
- each suggestion: a checkbox (pre-checked) + an editable title field,
- **"Add N tasks"** (N = checked count) and **"Cancel"**.

Accept → for each checked draft, `store.addTask(projectPath:title:ticket:X)`,
then clear the suggestion list and `reloadTickets`. The ticket flips from draft
to decomposed automatically (rollup), so the draft pill disappears.

### States
- Running: show a small spinner / "Suggesting tasks…" row in the ticket body.
- Empty result (no `TASK:` lines): show "No tasks suggested — try Deep mode or
  add manually." Do not write anything.
- Error (run failed): surface via existing `todoError` channel.

## Feature 2 — ambient injection on launch

`launchClaudeForTicket` already builds the seed prompt. It gains a prepended
block: the bodies of policies matching `appliesTo: "ticket", trigger: "on_work"`.
The breakdown policy carries both `on_demand` and `on_work`, so the button
(queries `on_demand`) and the launch path (queries `on_work`) both inject the
same policy text — one source, two consumers. When you launch Claude to *work* a
ticket, it carries the breakdown guidance and can decompose as it goes.

## Data flow

```
policy doc (lore)  ──read──>  PolicyStore  ──query(scope,trigger)──> [bodies]
                                                   │
ticket meta + child tasks ─────────────────────────┤
                                                   ▼
                                          suggestTasksForTicket
                                                   │ runClaude(taskSuggestion)
                                                   ▼
                                        claudeTasks output (TASK: lines)
                                                   │ parseSuggestedTasks
                                                   ▼
                              inline checklist (review/edit/check)
                                                   │ accept
                                                   ▼
                                   addTask(..., ticket:) × N  ──> rollup → decomposed
```

## Testing

Extend `TaskStoreSelfTest.swift` (existing in-app self-test harness):
- `PolicyStore.read` parses frontmatter incl. list fields (`applies_to`,
  `trigger`) and `status`.
- `policies(appliesTo:trigger:)` filters by status/scope/trigger and orders by
  priority then id; `any` matches; deprecated/draft excluded.
- `parseSuggestedTasks` already covered indirectly; add a direct case feeding
  known `TASK:` output → titles.
- Accept-suggestions path: adding N tasks links them to the ticket
  (`ticket:` set) and flips rollup to non-draft.

## Out of scope (follow-ups)

- Migrating other policies (commit conventions, verification, status hygiene,
  roadmap upkeep) into the new type. Mechanism ships with **one** real policy.
- Wiring non-core triggers (`on_start`, `before_merge`, `scheduled`, …).
- Sub-document `match:` filtering (e.g. `category: engineering` only) — for now,
  encode such conditions in policy prose and let the agent judge.
- Batch "decompose all draft tickets" sweep.
- Auto-on-create breakdown (explicitly rejected: fights the draft state, spends
  tokens on stubs).

## Decision record

A separate ADR (`docs/decisions/0012-…`) will record the *decision* to add a
`policy` lore type + app-side policy injection (vs. CLAUDE.md prose or lore
schema `prompt:`), and why `applies_to`/`trigger` are open lists. The ADR is
history; the policy docs are the living instructions.
