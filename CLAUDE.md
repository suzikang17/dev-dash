# dev-dash

Native macOS SwiftUI dashboard app for project/task management, devlogs, and AI-assisted lore workflows.

## Project structure

- `Sources/DevDash/` — Swift source
  - `Views/Tabs/` — tab views (Daily, LoreTasks, Docs, Preview, Info)
  - `Scanners/` — data scanners (git, lore, visual diff, product doc)
  - `Views/` — shared views and sheets
- `DevDash.app/` — app bundle (binary gitignored, `Info.plist` + `MacOS/.gitkeep` committed)
- `docs/` — project docs managed by lore
  - `docs/.lore/` — marker dir; schemas come from the lore package (run `lore eject <type>` to customize one locally)
  - `docs/devlog/` — session logs (day 1 = 2026-06-18)
  - `docs/tasks/` — task files
  - `docs/decisions/` — ADRs
  - `docs/ideas/` — idea backlog (promote to tasks)

## Tech stack

- Swift / SwiftUI, macOS 14+
- No external Swift dependencies (stdlib + AppKit/WebKit only)
- `lore` CLI on PATH (symlinked from `~/dev/lore/packages/cli/bin/lore.js` → `~/.local/bin/lore`) for doc indexing
- `claude -p` subprocess for AI generation (via `LoreRunner.swift`)

## Commands

- `bash run.sh` — debug build + codesign + launch
- `bash dist.sh` — release build, packages `DevDash-YYYYMMDD.zip`
- `swift build` — build only
- `lore reindex <type>` — reindex a lore doc type (run from repo root)
- `lore add <type> --title "..."` — create a doc; `lore eject <type>` — make a local schema override

## Conventions

- Commit directly to main
- Commit messages: imperative mood, concise
- SourceKit "Cannot find X in scope" errors are stale index noise — check with `swift build` before acting on them
- Use `browser.*` → N/A (native app); use `ShellRunner.run()` for subprocesses
- `LoreRunner` wraps all `claude -p` calls — don't shell out to Claude directly from views

## Lore doc flow

- Log a devlog entry in `docs/devlog/` after each session
- Run `lore reindex devlog` after adding entries
- Add decisions to `docs/decisions/` when a tool/pattern is chosen

## Worktrees

- dev-dash runs launched tasks in isolated git worktrees created under `.worktrees/` in the repo, on a branch `task/<id>-<slug>`, managed by `WorktreeManager`. `.worktrees/` is added to `.git/info/exclude` — never commit it.
- Each launched task's worktree path + branch are recorded on the task (lore frontmatter `worktree:` / `branch:`). Remove a worktree from the task's detail panel (or the "clean up" prompt after its PR merges) — don't `git worktree remove` it by hand while the app tracks it.
