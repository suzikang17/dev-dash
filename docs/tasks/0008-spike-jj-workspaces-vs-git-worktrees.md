---
lore_type: task
title: "Spike: jj workspaces vs git worktrees — head-to-head for parallel agents"
status: open
owner: human
category: research
priority: medium
effort: medium
created: '2026-06-30'
ticket: '0008'
---
Time-boxed evaluation (~1 day, one project, behind the existing `launchInWorktree` flag)
to decide whether jj workspaces are *convenient enough* to replace `WorktreeManager` for
running agents in parallel. Run the **same** multi-agent scenario on both substrates and
score management ergonomics against a hard GO / NO-GO bar. Reversible — delete jj, the
repo stays git. Per ADR [[0013-durable-agent-operation-log-jj-anchors]] and the
worktrees-vs-workspaces analysis.

## The scenario (run identically on git worktrees and jj workspaces)

- [ ] Launch **4 concurrent agents** on 4 tasks in one repo — each in its own worktree
      (control) / workspace (jj).
- [ ] One agent deliberately takes a bad path (failing change) → measure recovery.
- [ ] Two agents touch overlapping files → force a conflict at integration.
- [ ] Each agent's work pushed as a branch / bookmark → PR via the existing `gh` flow.

## What to measure (head-to-head, record both sides)

- [ ] **Setup ergonomics** — orchestration steps + lines to spin up one isolated sandbox.
      git: branch name + collision-retry + `.git/info/exclude` glue (`WorktreeManager`);
      jj: `jj workspace add`.
- [ ] **Central observability** — can the orchestrator get a *single* timeline of all 4
      agents' operations? git: no native; jj: shared op log. Yes/no + effort.
- [ ] **Per-agent rollback** — commands + time to cleanly revert the bad agent's work
      *without touching the other three*. git: `reset`/checkpoint glue; jj: `jj op restore`.
- [ ] **Conflict handling** — does the overlapping-files case block an agent mid-operation?
      git: blocks; jj: conflict-as-data, proceeds. Record whether the agent could continue
      unattended.
- [ ] **Change-id capture** — confirm jj exposes a stable `change_id` per workspace
      (`jj log -r @ -T change_id --no-graph`) that survives a rebase of the stack — the
      durable task→code anchor (folds in the former "change_id ramp"). On GO, persist it
      on the task via `TaskStore` next to `worktree:`/`branch:`.
- [ ] **Integration cost** — what breaks: `GitStatusScanner.parseWorktrees` (jj workspaces
      are invisible to `git worktree list`); does `jj workspace update-stale` fire when the
      app also runs plain `git`? Record the exact changes required.

## GO / NO-GO bar

- [ ] **GO (adopt jj workspaces)** if per-agent rollback **and** central observability are
      demonstrably simpler than the git equivalents, **and** integration cost is bounded to
      a `parseWorktrees` rewrite + `update-stale` handling (no deeper churn).
- [ ] **NO-GO (stay on `WorktreeManager`)** if ergonomics are a wash at this fleet size, or
      the pre-1.0 / `update-stale` friction outweighs the savings. Revisit at larger fleet
      scale.
- [ ] Record the verdict + evidence as a devlog entry and either a follow-up decision or an
      update to ADR 0013.

## Notes

Prototype *alongside* `WorktreeManager` behind the flag — do **not** migrate it in this
task. The whole point is a cheap, reversible measurement, not a commitment.
