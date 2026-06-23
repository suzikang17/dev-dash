---
lore_type: decision
title: "One StackedDiffView for commits, PRs, and Claude Code sessions"
date: 2026-06-22
category: architecture
revisit: false
---

## Why this choice

The Changes tab grew three "view modes" that all answer the same question — "show me
everything this thing changed": a commit, a GitHub PR, and a Claude Code session. Each
produces a multi-file diff. Rather than build three bespoke detail views, they all
funnel into one `StackedDiffView(title:subtitle:sections:)` that renders a header plus
every file as a collapsible side-by-side section in one scroll, with a jump bar and
shared vim scroll/keyboard plumbing. Each source just supplies `[FileDiffSection]`
(via `UnifiedDiffParser.parseMultiFile`) through a generic `loadStacked(key:...)`.

A sub-decision: a session's diff is computed against the **commit just before the
session started** (`git rev-list -1 --before=<startedAt>`) diffed to the working tree,
not against HEAD. Session-written files are usually already committed, so vs-HEAD
showed nothing.

## Options considered

- One generalized `StackedDiffView` + a `NavItem`/`activate` switch per source (chosen).
- Three separate detail views (commit/PR/session), each re-implementing scroll, jump
  bar, collapse, and vim handling.
- Session diff vs HEAD (rejected: empty once changes are committed) vs. vs
  pre-session commit (chosen) vs. reconstructing per-tool-call snapshots (no such data).

## Tradeoffs

- Gain: adding a new stacked source is a list + one `NavItem` case + one `activate`
  branch; all interaction behavior is shared and consistent.
- Give up: the header is generic (title/subtitle strings) rather than source-specific
  rich metadata. The session diff folds in any later edits to the same files (no
  per-session snapshots exist), and depends on `gh` auth for PRs.
