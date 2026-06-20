---
lore_type: devlog
created: 2026-06-19
title: "Lore init guidance + embedded per-project terminal drawer"
date: 2026-06-19
day: 2
---

**Added a "lore not initialized" guided empty state, then built a VS Code–style per-project terminal drawer on SwiftTerm — caught and fixed 4 process-lifecycle leaks via an adversarial multi-agent review.**

## What got done
- **Lore init guidance.** The Tasks (lore source) and Daily tabs used to render a silently-blank board when a project had no `docs/.lore/`. Added `LoreRunner.isInitialized(projectPath:)` (checks the `docs/.lore` marker dir), `LoreRunner.lorePath()` (mirrors `claudePath()`), and `runInit()` (`lore init docs` from the project root). New `LoreInitView` shows a one-click "Initialize lore" button that degrades to a copy-pasteable command if the CLI isn't found. Both tabs gate on init state and reload after.
- **Embedded terminal drawer.** Bottom drawer (⌘\` toggle, toolbar button disabled when no project) docked in `DetailPaneView`, available under any tab. New `TerminalSessionStore` caches one live `$SHELL -l` `LocalProcessTerminalView` per project so a running claude/build/lore survives tab + project switches; `TerminalHostView` mounts the cached NSView without respawning; `TerminalDrawer` has drag-resize, restart, close.
- **Adversarial review.** Ran a multi-lens review workflow (correctness, NSView lifecycle, process/PTY leaks, concurrency) with per-finding verification. 7 raised, 4 confirmed, 3 rejected as theoretical. Fixed all 4.

## Decisions
- **Reused the existing SwiftTerm dependency** rather than building a command console or launching external Terminal.app. SwiftTerm was already in `Package.swift` (used for nvim file viewing), so the "no external Swift deps" rule in CLAUDE.md was already relaxed — interactive Claude Code needs a real PTY + emulator, which SwiftTerm's `LocalProcessTerminalView` provides.
- **One live session per project, cached** (not single-shared or restart-on-switch) — the whole point is that a long-running claude/build keeps going when you navigate away.
- **Login shell (`$SHELL -l`)** because the GUI app's PATH is minimal; `-l` sources the user's profile so `lore`/`claude`/`node` shims resolve (same reason the nvim code shells out).

## Issues
- The naive terminal had real process-lifecycle leaks (all confirmed against the code): (1) no teardown on app quit — `AppDelegate` had no `applicationWillTerminate`, so forkpty'd shells + children reparented to launchd; (2) sessions never evicted when a project left the scan list — fds leak for the app's life; (3) SwiftTerm's `terminate()` only SIGTERMs the shell pid, not its job tree.
- Fixes: `terminateAll()` wired to `NSApplication.willTerminateNotification`; `reconcile(activePaths:)` on the `projects` didSet; `terminate(_:)` now does PTY-close (SIGHUP to the foreground job) **plus** `killpg(getpgid(pid), SIGKILL)` as a backstop.
- A headless runtime harness (`TerminalSelfTest`, run via `.build/debug/DevDash --selftest-terminal`) then caught a bug the static review missed: the killed shells lingered as **zombies** because SwiftTerm cancels its own child-exit reaper in `terminate()`, so nothing called `waitpid`. Diagnosed via libproc (`gone` to `proc_pidinfo` but `kill(pid,0)==0` = zombie signature). Fixed by reaping the killed child off the main thread (`waitpid`). All 10 lifecycle assertions pass.
- `lore init --help` is a trap: `lore init` treats `--help` as a path argument and actually initialized a stray `--help/` dir. Removed it.

## What to remember
- **Lore detection signal is the `docs/.lore/` marker dir.** Every scanner hardcodes `<projectPath>/docs/...`, so the init command is always `lore init docs` run from the project root.
- A foreground job under shell job-control lives in its **own** process group, so the SIGKILL backstop targets the shell's group while the PTY-close SIGHUP covers the foreground job. Together they tear down realistic cases (claude/builds don't trap SIGHUP); a deliberately-detached `nohup`/`&` daemon can still survive — expected terminal behavior, not a bug to chase.
- The `claude` tab (`ClaudeTabView`) is a `claude -p` composer, NOT an interactive terminal — kept as-is; the drawer is the interactive path.
- SourceKit "cannot find X in scope" on the new files was stale-index noise (build was clean).

---

## Commits
- 1116198 harden embedded terminal lifecycle; add runtime self-test
- (the lore-init guidance + initial terminal drawer landed in an earlier working-tree commit alongside the project one-pager / perf work)
