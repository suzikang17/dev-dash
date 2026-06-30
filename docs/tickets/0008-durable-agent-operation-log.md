---
lore_type: ticket
created: '2026-06-30'
title: Durable agent operation log + jj anchoring
status: open
category: engineering
---
Persist the in-memory hook event bus into a durable, append-only operation log; unify it
with the other event seams into a queryable timeline; and (if we adopt jj) anchor lore
docs to jj change-ids so task→code links survive rebase and undo becomes lore-native.

Design and rationale: ADR [[0013-durable-agent-operation-log-jj-anchors]].

Tasks:
- Persist the hook bus as append-only NDJSON (move #1) — task 0007.
- Spike: jj workspaces vs git worktrees head-to-head for parallel agents (folds in the jj `change_id` capture) — task 0008.
- Unified event timeline + regenerable SQLite view (move #2) — task 0009.
