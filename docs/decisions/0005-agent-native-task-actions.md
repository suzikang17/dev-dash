---
lore_type: decision
title: "Agent-native task actions: Claude acts through lore; dev-dash launches, renders, notifies"
date: 2026-06-24
category: architecture
revisit: true
---

## Why this choice

The hook event bus (see [[0004-claude-code-hook-event-bus]]) made dev-dash *observe*
Claude sessions and *feed* them context. The next step is the reverse write path: a
launched Claude session should act on dev-dash — update a task's status, file a
follow-up "review PR" task linked to the PR, produce artifacts that dev-dash renders,
and notify the user as these happen.

Key fact: **dev-dash is file-backed and those files are lore docs.** Tasks are
`docs/tasks/*.md`, devlogs `docs/devlog/`, decisions `docs/decisions/`, and the
running app watches those dirs (`NotesFileWatcher`/`TaskStore`) and re-renders on
change. lore already provides the write API for them:

- `lore add <type> --title "..." --fields k=v ...` — creates a doc; `--fields` spreads
  arbitrary frontmatter, so `lore add task --fields pr=<url>` files a PR-linked task
  with NO schema change.
- `lore set-status <type> <id> <status>` — updates `status:` AND appends
  `- <timestamp> old → new` to `## Status history` — the exact format `TaskStore` uses.

So a Claude session's **action surface is `lore`** (already on PATH). An earlier draft
of this ADR proposed a new `devdash` CLI for task create/status — that was redundant
duplication of `lore add` / `lore set-status` and is rejected.

dev-dash's job is only what lore can't do: (1) **launch** an interactive `claude` in
the embedded terminal seeded with the task spec + a one-line note on the `lore`
commands to report back; (2) **render** new shapes — a `pr:` task field as a live PR
card (reusing `GitDiffScanner.prDetail/openPRWeb`), and artifacts; (3) **notify** via
native macOS notifications. Launched sessions and their outputs attach to the **task**
(durable, git-tracked), not the ephemeral session.

## Options considered

- **Action surface:** new `devdash` CLI over the files (rejected — duplicates lore) vs.
  **`lore` (chosen — already does add + set-status with arbitrary fields)** vs. full MCP
  now (deferred; when wanted, an MCP tool is a one-line shell to `lore` or a dev-dash
  subcommand; the localhost hook server is the natural host).
- **Launch target:** **embedded terminal (chosen)** vs. headless `claude -p`
  (existing `runForTask`) vs. external Terminal.app.
- **Attach to:** **task (chosen)** vs. session vs. both.
- **Artifacts (decided):** a new lore `artifact` doc type — markdown with
  `--fields task=<id>`, indexed/searchable, consistent with the doc model; binary
  outputs (screenshots, images, diffs) are referenced from the artifact doc rather
  than stored as lore docs. Requires adding the `artifact` type to the lore package.
- **PR link:** plain `pr:` frontmatter via `lore add --fields` (chosen — no schema
  change) vs. ejecting the task schema to formalize it (later, if validation wanted).
- **Notifications:** native `UNUserNotificationCenter` (app is signed w/ bundle id),
  fired from hook/file-watch handlers, with a Settings toggle.

## Tradeoffs

- Gain: the write loop reuses lore wholesale — no new CLI, no schema change for PR
  links, status history stays consistent. dev-dash adds only launch + rendering +
  notifications. Durable, git-tracked, MCP-upgradeable.
- Give up: lore invocations are convention-validated, not a typed contract (acceptable;
  far safer than hand-written frontmatter). Artifacts still need one design choice.
- Risk (revisit): if non-doc actions appear ("open PR in browser", "trigger deploy") or
  validation/discovery is wanted, promote to MCP tools that shell `lore`/dev-dash.

## Build stages

1. Launch — "Launch with Claude" on a task → embedded terminal runs interactive
   `claude` seeded with the task spec + a note on the `lore` report-back commands;
   sets owner=ai.
2. PR-linked task rendering — render a task's `pr:` field as a live PR card (reuse the
   `gh` machinery). Creation already works via `lore add task --fields pr=<url>`.
3. Artifacts — add an `artifact` type to the lore package; render artifact docs for a
   task in an artifacts panel in task detail (md/web/diff/image renderers exist),
   filtered by their `task=<id>` field; binaries referenced.
4. Notifications — `UNUserNotificationCenter` on PR-task created / status change / new
   artifact / session end, with a Settings toggle.
