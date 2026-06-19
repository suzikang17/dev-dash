# dev-dash

Native macOS SwiftUI dashboard app for project/task management, devlogs, and AI-assisted lore workflows.

## Project structure

- `Sources/DevDash/` — Swift source
  - `Views/Tabs/` — tab views (Daily, LoreTasks, Docs, Preview, Info)
  - `Scanners/` — data scanners (git, lore, visual diff, product doc)
  - `Views/` — shared views and sheets
- `DevDash.app/` — app bundle (binary gitignored, `Info.plist` + `MacOS/.gitkeep` committed)
- `docs/` — project docs managed by lore
  - `docs/.lore/types/` — schema files (devlog, task, decision, idea)
  - `docs/devlog/` — session logs (day 1 = 2026-06-18)
  - `docs/tasks/` — task files
  - `docs/decisions/` — ADRs

## Tech stack

- Swift / SwiftUI, macOS 14+
- No external Swift dependencies (stdlib + AppKit/WebKit only)
- Node.js CLI: `~/dev/lore` (`@lore/core` + `@lore/cli`) for doc indexing
- `claude -p` subprocess for AI generation (via `LoreRunner.swift`)

## Commands

- `bash run.sh` — debug build + codesign + launch
- `bash dist.sh` — release build, packages `DevDash-YYYYMMDD.zip`
- `swift build` — build only
- `node ~/dev/lore/packages/cli/dist/cli/index.js reindex <type>` — reindex a lore doc type (run from repo root)

## Conventions

- Commit directly to main
- Commit messages: imperative mood, concise
- SourceKit "Cannot find X in scope" errors are stale index noise — check with `swift build` before acting on them
- Use `browser.*` → N/A (native app); use `ShellRunner.run()` for subprocesses
- `LoreRunner` wraps all `claude -p` calls — don't shell out to Claude directly from views

## Lore doc flow

- Log a devlog entry in `docs/devlog/` after each session
- Run `node ~/dev/lore/packages/cli/dist/cli/index.js reindex devlog` after adding entries
- Add decisions to `docs/decisions/` when a tool/pattern is chosen
