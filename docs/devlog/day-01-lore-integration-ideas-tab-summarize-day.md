---
title: "Day 1 — dev-dash: lore integration, Ideas tab, summarize-day"
date: "2026-06-18"
day: 1
phase: Tooling
---

**Wired lore's AI workflows into dev-dash via `claude -p`, added Ideas tab with promote-to-task, and a summarize-day button on the daily view.**

## What got done

- **LoreRunner.swift** — new Swift helper that wraps `claude -p` subprocess calls; handles Claude binary discovery, schema prompt extraction from `.lore/types/*.schema.yaml`, `nextId()`, `slug()`, and `parseFM()`
- **Ideas tab** in LoreTasksView — third view mode showing docs from `docs/ideas/`; each row has title, status chip, category, and a promote button
- **Promote to task** — reads idea body, calls `LoreRunner.generate()` with the task schema prompt via `claude -p`, writes the generated task file, marks idea as `promoted` with `promoted_to` link, reloads both lists
- **Summarize-day button** — wand icon on each day header in DailyTabView; scans `## Status history` lines across all task files for that date, calls `LoreRunner.generate()` with the devlog schema prompt, writes output to `docs/devlog/`
- **`idea` doc type** — added `idea.schema.yaml` to cliphy's `.lore/types/` (statuses: raw/promising/promoted/parked; `promoted_to` field)
- **`idea-to-task` CLI command** — added to lore CLI for running the promote workflow outside of dev-dash
- **`dist.sh`** — release packaging script: `swift build -c release`, copies binary + JS into `DevDash.app`, ad-hoc codesigns, zips to `DevDash-YYYYMMDD.zip`
- **Task audit** — reviewed all open tasks; marked 0073, 0048, 0076, 0077, 0078, 0115 as done

## Decisions

- **`claude -p` over URLSession/Anthropic SDK** — avoids bundling Node.js or managing API keys in the app; Claude Code is already installed and authenticated. Simpler, and it means lore's schema prompts drive generation the same way they do from the CLI.
- **`@Binding var selectedId: UUID?` instead of `LoreTaskItem?`** — passing the full struct to a `LazyVStack` row caused all rows to re-render on selection (expensive struct comparison). UUID is a 16-byte value type; rows observe only the ID they need.

## Issues

- **Row highlight not working on Needs tab** — first attempt moved the background modifier to the parent helper view; that broke both tabs because `LazyVStack` doesn't re-evaluate parent-computed properties when state changes. Second attempt used `@Binding var selected: LoreTaskItem?` which caused a freeze on click. UUID binding fixed it.
- **`>-` showing as title** — `parseLoreFM` was reading the literal scalar indicator instead of consuming the indented continuation lines. Switched to an index-based loop.
- **SourceKit false positives** — "Cannot find LoreRunner/DashboardStore in scope" throughout the session; actual builds succeed. Stale index.
- **lore CLI `idea-to-task` arg parsing bug** — was reading `rest[0]` for the slug; args are `[cmd, typeName, ...rest]` so it should be `typeName` directly.

## What to remember

- `LazyVStack` row selection state must be bound at the row level via `@Binding`, not computed in the container — the lazy loading means the container's state changes don't propagate to already-rendered rows.
- `claude -p "<prompt>"` works as a non-interactive subprocess from Swift via `ShellRunner.run()`. CWD must be set to the project path so Claude picks up project context.
- dev-dash's `dist.sh` produces an ad-hoc signed `DevDash.app` — first launch on another Mac requires right-click → Open to bypass Gatekeeper.

---

## Commits

- `5900439` lore ideas tab, summarize-day, LoreRunner; visual diff, git status, product doc scanners (dev-dash)
- `f6e4d5e` lore tasks: UUID binding fix, YAML block scalar parser, dist.sh (dev-dash)
