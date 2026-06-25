---
lore_type: decision
title: "Tickets contain Tasks: a deliverable (ticket) holds work-step tasks, each with its own owner"
date: 2026-06-25
category: architecture
revisit: true
---

## Why this choice

The agent-native work ([[0005-agent-native-task-actions]]) and the worktree workflow
exposed a missing layer. A unit like "Add auth" is a *deliverable*; the steps inside
it — write the code, review the PR, QA — are distinct pieces of work, often done by
different actors (a human, or a specific AI agent) on different clocks. Modelling all
of that as one flat "task" with a single owner and a single status column can't express
"the code is written (AI) but the review is pending (you or a review-agent)".

So: a **Ticket** is the deliverable (≈ a Linear issue / a PR's worth of work). A
**Task** is a work step inside a ticket, with its OWN owner (human or a named agent)
and its own state. Tasks nest (a Task can have child Tasks = **Subtasks**), giving
arbitrary depth. This makes "review" a first-class Task — orthogonal to the code Task,
routable to a human OR an agent, and surfaced in a per-owner queue ("everything a human
needs to do" = all Tasks owned by human).

## Decision (chosen: Ticket-on-top, keep Task as the work item)

- **New lore `ticket` type** = the container (`docs/tickets/*.md`). Mirrors the task
  schema (title, status, owner?, category, pr, created, …). `lore add ticket`.
- **Existing `task` type stays** = the work item (`docs/tasks/*.md`). Unchanged so the
  whole agent-native loop (`lore add task`, PR→review, artifacts) keeps working. A Task
  gains a `ticket:` frontmatter field (the owning ticket id); `parent:` continues to
  mean a parent *task* (for Subtasks). `lore add task --field ticket=<id>`.
- **Migration**: today's top-level task docs (the current to-dos) migrate to tickets
  (`docs/tasks/<n>` → `docs/tickets/<n>`), carrying their fields. Existing child tasks
  keep `parent:` and gain `ticket:` pointing at the migrated ticket. Idempotent,
  self-tested, non-destructive (originals backed up); leaves a marker so it runs once.
- **dev-dash**: a `TicketStore` (reads/writes `docs/tickets/*.md`, same lore-adapter
  discipline as `TaskStore`). The UI shows Tickets at the top level; expanding a ticket
  shows its Tasks (and Subtasks). Per-owner queue aggregates Tasks by owner.
- **Agent-native mapping**: launch is at the **Task** level (a work step under a
  ticket). `gh pr create` creates a **review Task** under the ticket (instead of moving
  the ticket's column). Artifacts link to a Task. Worktrees attach to a Task.

## Options considered

- **Ticket-on-top, keep Task (chosen)** — preserves the agent-native `task` machinery,
  cleaner vocabulary (Claude works on Tasks; Tasks live in Tickets); cost is a new type
  + a scoped migration of top-level tasks → tickets.
- **Rename the single type task→ticket** (rejected) — simplest structure but ripples
  task→ticket through every agent-native command, the launch prompt, artifact links, and
  the 109-check self-test, and the CLI would say "ticket" at every depth.
- **UI labels only** (rejected earlier) — cheapest, but the user wants the storage/CLI
  to reflect the two levels.

## Tradeoffs

- Gain: the model the workflow actually needs — review (and any step) as a first-class,
  separately-owned Task; per-owner queues; clean Subtask headroom; Tickets map to Linear
  issues.
- Give up: a second store/type and a second data migration right after the lore-adapter
  one; more concepts; the agent-native loop must learn the Ticket↔Task relationship.
- Risk (revisit): scope creep into a generic workflow engine. Keep it to two types +
  nesting; evolve, don't pre-build.

## Build stages

1. lore `ticket` type + dev-dash `TicketStore` (lore-adapter style) + migration of
   top-level tasks → tickets (children re-pointed via `ticket:`), with self-test.
2. UI — Tickets as the top level; Tasks/Subtasks nested within; per-owner queue.
3. Agent-native re-wire — launch at the Task level under a ticket; PR→review creates a
   review Task; artifacts/worktrees attach to Tasks; the Ticket reflects rollup state.
