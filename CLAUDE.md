# dev-dash

Native macOS SwiftUI dashboard: an agent-native cockpit for multi-project dev —
tickets/tasks/policies as lore markdown, Claude sessions reporting in over a
localhost hook event bus, embedded terminals, living product doc, iOS-simulator
canvas. Full structural map: `docs/ARCHITECTURE.md` (read it before store,
scanner, or cross-tab work).

## Project structure

- `Sources/DevDash/` — Swift source
  - top level — stores (`DashboardStore` hub + `TabStore`/`ServerStore`/`CanvasStore`), `Models.swift`, self-tests
  - `Views/` — chrome (sidebar, split view, sheets, canvas, terminals)
  - `Views/Tabs/` — detail tabs (LoreTasks, Changes, Daily, Info, Claude, Product, Preview, Logs)
  - `Scanners/` — ALL data + subprocess code: enum stores (TaskStore/TicketStore/PolicyStore/…), git/lore/session scanners, runners
- `DevDash.app/` — app bundle (binary gitignored; `Info.plist` + `MacOS/.gitkeep` committed)
- `docs/` — lore-managed: `devlog/` (day 1 = 2026-06-18), `tasks/`, `tickets/`, `policies/`, `decisions/`, `ideas/`, `artifacts/`, `notes/`
  - `docs/.lore/` — marker dir; local schema overrides in `.lore/types/`

## Tech stack

- Swift / SwiftUI, macOS 14+, **no external Swift dependencies** (stdlib + AppKit/WebKit only)
- `lore` CLI on PATH (`~/.local/bin/lore`; non-interactive shells: `node ~/.local/bin/lore`)
- `claude -p` subprocesses via the runner stack (`ShellRunner` → `ClaudeRunner`/`LoreRunner`); never shell out to Claude from views
- Metal shaders precompiled to `default.metallib` by `run.sh` (needs the Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`)

## Commands

- `bash run.sh` — debug build + shader compile + codesign + launch
- `bash dist.sh` — release build, packages `DevDash-YYYYMMDD.zip`
- `swift build` — build only
- Self-tests (headless, no XCTest): `swift build && .build/debug/DevDash --selftest-taskstore | --selftest-policy | --daily-selftest | --selftest-terminal` — run the relevant suite before claiming a data-layer change done
- `lore reindex <type>` / `lore validate <type>` — after editing lore docs (note: decision type is singular, `lore reindex decision`)

## Conventions

- Commit directly to main; imperative mood, concise messages
- SourceKit "Cannot find X in scope" cross-file errors are stale-index noise — trust `swift build`
- Reuse `TaskStore` frontmatter helpers (`parseTaskFrontmatter`, `setOrAddFrontmatterKey`, `yamlStr`) — never reimplement frontmatter parsing
- Lore multi-value frontmatter = comma-separated strings (`applies_to: ticket, task`), NOT YAML brackets — lore has no list type (ADR 0012)
- New lore doc mutations go through the enum stores (`TaskStore`/`TicketStore`/`PolicyStore` pattern); keep them stateless static funcs
- `BaguetteRunner.shared` is a machine-wide singleton — never spawn a second `baguette serve`

## Performance guardrails (violations have caused real UI lag — see ARCHITECTURE.md §guardrails)

- No synchronous file I/O on the main actor from `body`/`.onAppear`/`.onChange` — `Task.detached` + `MainActor.run` write-back
- Batch `@Published` dict writes: one assignment per refresh, not one per project (DashboardStore has ~64 publishers; every mutation fans out everywhere)
- Prefer the single-file/single-project reload paths (`updateInPlace`, `reloadTasksAndNotifyForProject`) over directory-wide rescans
- Don't filter/sort large collections inside view `body` — memoize
- Static `DateFormatter`s only; never allocate one in a per-file loop

## Agent-native model (how the pieces fit)

- **Ticket** (`docs/tickets/`) = deliverable; contains **Tasks** (`docs/tasks/`), each with its own owner (human/ai) — ADR 0010. Task-less tickets show as "draft"; break down via ticket context menu (policy-driven suggestion → inline review)
- **Policies** (`docs/policies/`) = agent behavior as data; app injects `active` ones into prompts by `applies_to`/`trigger` — ADR 0012. Edit the doc to change agent behavior, no code change
- **Hook event bus**: Claude sessions POST to `EventServer`; `cwd` joins session → project — ADR 0004. Agent's write path is the `lore` CLI (ADR 0005); `NotesFileWatcher` picks up external doc writes
- **Operation log** (ADR 0013): every hook event is appended as NDJSON to `<project>/.devdash/events/<date>.ndjson` (source of truth; unmatched → `~/.devdash/events/_unmatched.ndjson`); `recentEvents` is a 300-cap tail restored from today's files on launch. Write via `EventLogStore` only (crash-safe seek-to-end appends). Query view (SQLite) is task 0009, still open

## Lore doc flow

- Devlog after each session via `/devlog`; ADRs in `docs/decisions/` when a tool/pattern is chosen; `lore reindex <type>` after adding docs
- A local pre-commit hook runs `lore validate --all` (errors block, warnings pass; bypass with `--no-verify`). After any schema change, heal docs with `lore migrate <type>` (dry-run) then `--write`
- Do NOT bulk-rename `lore_type:` → `type:` in docs here (`lore migrate` offers it): dev-dash's stores still write `lore_type` and `DailyTabView` reads it; lore accepts it as a legacy alias indefinitely

## Worktrees

- Launched tasks run in isolated worktrees under `.worktrees/` on branch `task/<id>-<slug>` via `WorktreeManager`; `.worktrees/` is in `.git/info/exclude` — never commit it. Worktree path + branch recorded in task frontmatter (`worktree:`/`branch:`). Remove via the task detail panel, not `git worktree remove` by hand.
