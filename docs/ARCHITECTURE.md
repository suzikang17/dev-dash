# dev-dash architecture

Native SwiftUI macOS app (~37k lines Swift, SPM, no external dependencies): a
multi-project developer dashboard wrapping Claude Code, `lore` (markdown
knowledge-graph CLI), git, and an embedded iOS simulator. Direction (ADRs
0004→0013): an **agent-native cockpit** — Claude sessions report in over a hook
event bus, act on projects through lore docs, and dev-dash renders/routes it all.

## Layers

```
App.swift (@main)
 └─ DashboardStore (@MainActor hub, owns everything)
     ├─ TabStore          — active detail tab (split out: ⌘1-9 shouldn't republish the world)
     ├─ ServerStore       — dev-server logs/state (split out: log lines stream many×/sec)
     ├─ CanvasStore       — per-project freeform canvas layouts
     └─ TerminalSessionStore — embedded terminal PTYs (plain class, not observable)
 Views/            — chrome: SidebarView, ContentView (NavigationSplitView), DetailPaneView (tab router),
                     TaskDetailSheet, SettingsView, SimulatorEmbedView, CanvasView, terminal stack
 Views/Tabs/       — the detail tabs: LoreTasks, Changes, Daily, Info, Claude, Product, Preview, Logs
 Scanners/         — ALL data + subprocess code (60 files): enum stores, scanners, runners
 Models.swift      — value types (Project, Service, TaskItem, Ticket, Policy, ClaudeTask, …)
```

### Store layer (ObservableObjects)

`DashboardStore` is the root and instantiates the child stores; `App.swift`
injects `store`, `store.serverStore`, `store.tabStore`, `store.canvasStore` as
environment objects. It holds the per-project dictionaries keyed by path:
`projectMeta / projectTasks / projectTickets / projectPolicies / projectHealth /
gitStatuses / sessionDigests / liveSessions / claudeTasks`, plus hook-bus state
(`eventServerPort`, `recentEvents`, `lastHookBanner`).

**Known hotspot:** DashboardStore has ~64 `@Published` properties; every
mutation fans out to nearly all views. TabStore/ServerStore were split out for
exactly this reason. Prefer batching dictionary writes (one assignment, not N
per-key mutations) over adding more publishers.

### Data layer (the "lore-adapter" pattern)

Stateless `enum` stores in `Scanners/` — namespaces of static funcs, no
instances. Markdown-backed ones read/write `<project>/docs/<type>/<id>-<slug>.md`:

| Store | Dir | Notes |
|---|---|---|
| `TaskStore` | `docs/tasks/` | owns the shared frontmatter helpers |
| `TicketStore` | `docs/tickets/` | deliverable; contains tasks (ADR 0010) |
| `PolicyStore` | `docs/policies/` | agent policies; only `active` injected (ADR 0012) |
| `ArtifactStore` | `docs/artifacts/` | read-only |
| `DailyPageStore` | `docs/notes/` | daily pages |
| `LoreReader` | any `docs/<type>/` | generic |

**The shared helpers live on `TaskStore`** — `parseTaskFrontmatter`,
`setOrAddFrontmatterKey`, `removeFrontmatterKey`, `yamlStr` — and every other
store reuses them. Never reimplement frontmatter parsing. Multi-value lore
fields are **comma-separated strings** (lore has no list type; see ADR 0012);
`PolicyStore.parseList` is the canonical splitter.

JSON/Keychain-backed: `GroupStore` (`~/.devdash/groups.json`),
`ProjectMetaStore`/`ProviderStore`/`HealthStore`/`ServerStateStore`/`RecapStore`
(`.devdash/*.json`), `KeychainStore` (Linear key).

### Subprocess / AI stack

1. `ShellRunner` — base `Process` wrapper; `start()` → `RunningProcess` with an
   async `lines` sequence (fixes pipe-buffer deadlock).
2. `ClaudeRunner` — builds `claude -p <prompt> --output-format stream-json`,
   returns a `RunningProcess`. Uses the user's CLI auth.
3. `LoreRunner` — one-shot doc generation: pulls a lore schema prompt, runs
   `claude -p` (e.g. auto-devlog).

`DashboardStore.runClaude(prompt:projectPath:allowEdits:kind:)` is the pipeline:
creates a `ClaudeTask` (kinds: general/recap/releaseNotes/taskExecution/
taskSuggestion/roadmapUpdate), streams stream-json lines into `task.output` on
the MainActor, marks completion, writes back to lore for linked tasks.
**Views never shell out to Claude directly — always through the store/runners.**

### Hook event bus (ADR 0004, 0013)

`EventServer` — localhost HTTP receiver; Claude Code hooks POST session events,
`cwd` is the join key to a project. `HookInstaller` writes hook entries into a
project's `.claude/settings.json`. In-flight (ADR 0013): persist the bus as
append-only NDJSON at `.devdash/events/<date>.ndjsonl`; `recentEvents` becomes a
capped tail.

### Scanners (selected)

Git: `GitScanner`, `GitStatusScanner`, `GitDiffScanner`, `RecentCommitsScanner`,
`WorktreeManager` (task worktrees under `.worktrees/`). Lore: `LoreLinkIndex`
(backlinks), `NotesFileWatcher` (FSEvents on `docs/` — external Claude/editor
writes re-render). Product: `ProductDocGenerator` (living-doc HTML site, 1.8k
lines — historically hot). Simulator: `SimAppRunner` (xcodebuild pipeline),
`BaguetteRunner.shared` (singleton `baguette serve` :8421 for the WKWebView
embed — one per machine, do not spawn more). Sessions: `SessionScanner`,
`ClaudeSessionParser` (`~/.claude/projects/*/*.jsonl`). Integrations:
`LinearScanner`, `VercelScanner`, `ProviderDetector`.

### Refresh model

App launch → `startEventServer()` + `refreshAll()` (also on a 15s tick):
`ProcessScanner` → services, `ProjectScanner.scanAll()` → projects,
`SessionScanner` → sessions, per-project `GitStatusScanner` → `gitStatuses`.
`loadProjectMetaAndTasks()` reads the lore stores per project.
`NotesFileWatcher` re-reads on external doc writes. Push (hook events) is
preferred over polling for anything session-related.

## Self-tests (headless, no XCTest)

CLI-flag harnesses invoked from `DevDashApp.init()`, print `ok`/`FAIL` lines,
exit non-zero on failure:

| Flag | Suite |
|---|---|
| `--selftest-taskstore` | TaskStore/TicketStore round-trips, migrations, worktrees |
| `--selftest-policy` | PolicyStore parsing, query, prompt injection |
| `--daily-selftest` | DailyPageStore, SupertagRegistry |
| `--selftest-terminal` | terminal session logic |
| `--regen <path>` | living-doc regeneration CLI |
| `--dump-tasks <path>` / `--dump-projects` / `--migrate-tickets <path>` | diagnostics |

Run: `swift build && .build/debug/DevDash --selftest-policy` etc.

## Performance guardrails (learned the hard way)

1. **No synchronous file I/O on the main actor from view lifecycle** —
   `.onAppear`/`.onChange`/body must not call `String(contentsOfFile:)` loops.
   Offload with `Task.detached` + `MainActor.run` write-back (see
   `DailyTabView.reload`, `refreshSessionDigests` for the pattern).
2. **Batch `@Published` dictionary writes.** One assignment per refresh, not one
   per project/key — each mutation republishes to every observer.
3. **Incremental over full rescan.** Single-file mutations should use the
   single-file paths (`LoreTasksView.updateInPlace`,
   `reloadTasksAndNotifyForProject`) — not directory-wide re-reads of all
   projects.
4. **Don't compute in `body`.** Memoize filtered/sorted collections; a
   keystroke in search must not re-filter every task × ticket.
5. **Reuse `DateFormatter`s** (static) — never allocate inside per-file loops.
6. **One subprocess where two would do** — git scanners run per project per
   tick; batch or share invocations when touching that code.
7. Largest files (`DashboardStore` 3.5k, `LoreTasksView` 1.9k,
   `ProductDocGenerator` 1.8k) are refactor-pressure zones: prefer extracting
   into `Scanners/` enums or child stores over growing them.

## Decision history

ADRs in `docs/decisions/` — key ones: 0004 hook event bus, 0005 agent-native
task actions (`lore` is the agent's action surface), 0008 Linear, 0010 tickets
contain tasks, 0012 policy lore type, 0013 durable NDJSON operation log + jj
change-id anchoring. Devlogs in `docs/devlog/` track day-by-day evolution.
