---
type: devlog
title: "Day 8 — isolated worktree task workflow: launch → branch → PR → Review & QA → cleanup"
date: "2026-06-25"
day: 8
phase: Tooling
---

**Closed the isolated agent workflow: launching a task creates its own git worktree + branch, opening a PR auto-moves the task to Review & QA with the PR attached, worktrees nest under their repo in the sidebar, and cleanup is prompted on merge — never automatic.**

## What got done

- **PR → Review & QA** — the `PostToolUse` hook detects an anchored `gh pr create`, parses the PR URL from `tool_output`, and (only when the linked task is in "AI Working") sets the task's `pr:` field + hasAIRun + owner=human → lands it in Review & QA, with a notification. Idempotent; never clobbers done/blocked tasks.
- **Sidebar worktree grouping** — worktrees now nest (collapsible) under their parent repo instead of cluttering as flat siblings. Fixed the root cause in `GitStatusScanner`: `isMain` was keyed off the scanned dir, so every checkout marked itself main — which also silently broke the existing `⊞` indicator.
- **Worktree-per-launched-task** (opt-in, default on) — `WorktreeManager` creates `<repo>/.worktrees/task-<id>-<slug>` on branch `task/<id>-<slug>`; the embedded terminal runs there; the worktree+branch are recorded on the task. Task detail surfaces it (Open terminal / Remove), plus a "clean up worktree" prompt once the PR merges. `.worktrees/` is added to `.git/info/exclude`; documented in CLAUDE.md.

## Decisions

- **Move the existing task to Review & QA, not file a separate review task** — the PR open IS the "needs approval" signal, and `(open, human, hasAIRun)` already maps to the Review & QA column. Attaching the PR to the task it belongs to beats spawning a parallel doc.
- **Hidden, dev-dash-tracked worktrees + prompt-on-merge cleanup** — worktrees live under `.worktrees/` (git-excluded) and the app tracks them via task frontmatter; cleanup is always an explicit button (manual or post-merge prompt), never automatic deletion.
- **Gate worktree creation on file-backed tasks** — only tasks with a `docs/tasks` file get a worktree, so non-file-backed (e.g. Linear) tasks can't orphan a worktree that can't be recorded.

## Issues

- **Sidebar grouping shipped as a no-op first pass** — `groupWorktrees` keyed off `isMain`, which was wrong everywhere (set to `path == scanDir`). Caught by review; fixed at the scanner (primary = first `git worktree list` entry) and locked with a `groupWorktrees` self-test.
- **Destructive-git safety on real repos** — adversarial review caught two teeth before any real-repo damage: `branch -D` trusted an editable `branch:` frontmatter field (now verified against the worktree's actual HEAD), and launching a non-file-backed task created an orphan worktree (now gated). Also narrowed the create() collision classifier (bare `"branch"` matched almost every git error → burned retries) and made the `.git/info/exclude` write append-only.

## Verified

- `--selftest-taskstore` 109/109 (incl. PR-promote source-guard, worktree grouping fixtures, `slugBranch`/`makeSlug` naming, worktree field round-trip, collision-phrase classifier). End-to-end `lore`→dev-dash round-trip confirmed earlier; the worktree git mutations are guarded to never touch the main checkout or delete an unrelated branch.
