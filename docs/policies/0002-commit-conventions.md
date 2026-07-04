---
lore_type: policy
title: Commit conventions
applies_to: project
trigger: on_work
status: active
---
Commit style for this repo: commit directly to main — except in a launched task
worktree, where you stay on the task branch and open a PR when done.

Messages: imperative mood, concise, lowercase conventional prefix when it fits
(feat:, fix:, perf:, docs:, refactor:, chore:). One logical change per commit —
don't bundle unrelated files. Never commit `.worktrees/`, app-bundle binaries,
or generated `docs/devdash/` HTML unless the change is intentional.
