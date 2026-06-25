---
title: "Day 8 — Tickets contain Tasks: a deliverable holds work-step tasks, review becomes its own to-do"
date: "2026-06-25"
day: 8
phase: Tooling
---

**Introduced a two-level work model — a Ticket (deliverable) holds Tasks (work steps, each with its own owner) — migrated existing tasks to tickets live, and re-wired the agent-native loop so a PR opening creates a Review Task under the ticket instead of flipping a column.**

## What got done

- **lore `ticket` type** (merged to lore main) — the deliverable container (`docs/tickets`); a Task references its ticket via a `ticket:` frontmatter field; subtasks via `parent:`.
- **Ticket data layer** — `Ticket` model + `TicketStore` (lore adapter over `docs/tickets`, reusing TaskStore's frontmatter helpers); `TaskItem.ticket` field.
- **task→ticket migration** (`TicketMigrator`) — converts top-level task docs to tickets by rewriting the doc in place (`lore_type` task→ticket + `migrated_from`), preserving ALL fields/keys/status history; re-points children (`ticket=<root>`, parent cleared for direct children, kept for deeper subtasks); orphan parents promoted; resumable/idempotent (topLevel requires `parent==nil && ticket==nil` + `migrated_from` dedup); non-destructive backups. Gated, triggered off-main on load.
- **Tickets UI** — `LoreTasksView` default mode is now Tickets: Ticket → Task → Subtask hierarchy, PR badge, computed rollup status + `N/M done`, create-ticket / add-task-to-ticket.
- **Agent-native re-wire** — `launchClaudeForTicket` creates+launches a work Task under a ticket (gets the worktree); `gh pr create` marks the work Task done and creates a **Review PR Task** (owner=human) under the same ticket; idempotent; legacy fallback for ticketless tasks.
- **ADR 0009** — plan to bundle lore's `dist` into the app (CLI, not a Swift dep) for app↔lore version compatibility at ship-time; deferred (lockstep while both repos are local).

## Decisions

- **Ticket-on-top, keep Task as the work item** (over renaming `task`→`ticket`) — preserves the whole agent-native loop built on the `task` type; cleaner vocabulary (Claude works on Tasks; Tasks live in Tickets); arbitrary subtask nesting via the existing tree.
- **Review as its own Task, not a column** — writing the code and reviewing it are two acts by (potentially) two actors on two clocks. PR-open ends the work Task and spawns a human-owned Review Task — routable, queue-able, orthogonal.
- **Rollup is display-only** — a ticket's status is computed from its tasks at render; the stored status stays a manual override (no churn).

## Issues

- **Migration P0 caught while gated** — a partial run could have promoted cleared-parent children into duplicate tickets on the next run. Fixed: `topLevel` requires `parent==nil AND ticket==nil`; `migrated_from` dedup; rewrite-in-place preserves everything. 174→179-check self-test covers interrupted re-run, orphans, non-numeric ids, 4-level chains, key preservation.
- **Verify-on-copies-then-live** — ran the migration on temp copies of CXExcellent + dev-dash first (3 tasks → 3 tickets, backups, nothing lost), then live; both real projects migrated cleanly, originals backed up to `.devdash/migrated-tasks/`.

## Verified

- `--selftest-taskstore` all pass (incl. migration edges, PR→review-task creation + dedup, rollup). Live migration verified on real CXExcellent + dev-dash repos (tickets created, titles preserved, backups present, zero data loss). dev-dash's own docs migrated + reindexed + committed.
