---
lore_type: devlog
created: 2026-07-08
title: "Subprocess leak cleanup: rip out nvim, kill orphaned agents"
date: 2026-07-08
day: 21
---

**TL;DR: Traced a laggy machine to 21 orphaned `nvim --embed` processes from dev-dash, discovered the spawner was already dead code and deleted it, then audited for the same bug class and fixed three more orphan-on-quit subprocess leaks.**

## What got done
- Deleted `Views/EmbeddedTerminal.swift` (207 lines). It spawned `nvim --embed` (and a glow/bat source viewer) via SwiftTerm but had **zero remaining call sites** — replaced by the glow/bat Source mode (`14c0caa`) and later a WebView viewer. It also had no teardown, so it leaked one nvim per file viewed and orphaned them on crash.
- Ran a two-front leak audit (process/service lifecycle + `NSViewRepresentable` teardown) and fixed three real orphan-on-quit leaks:
  - **DashboardStore**: in-flight `claude -p` agents had no app-termination teardown → Cmd-Q reparented them to launchd where they kept editing the repo and burning tokens. Added a `willTerminate` observer → `stopAllRunningClaude()`.
  - **SimAppRunner**: added the same `willTerminate` hook so an in-flight `xcodebuild` is killed on quit (`deinit` isn't delivered before Cmd-Q).
  - **ShellRunner**: `stop()` already called `kill(-pid)` intending a process-group kill, but the child was never made a group leader, so it hit nothing and grandchildren of `zsh -ic "…"` wrappers survived cancel. `setpgid` the child on spawn; escalate SIGKILL to the group too.
- Verified: `swift build` green, `--selftest-terminal` 10/10.

## Decisions
- **Delete rather than fix the nvim spawner.** The reflex was to add `dismantleNSView` teardown, but the code had no callers — the right fix for dead code is deletion, not lifecycle plumbing. Confirmed three ways (no type refs, no `.neovim(`/`.sourceViewer(`/`EmbeddedTerminal(` call sites) before removing.
- **Mirror the existing `willTerminate` pattern** (BaguetteRunner / TerminalSessionStore) for the agent-teardown fixes rather than inventing a new mechanism — `DashboardStore` was simply the sibling that missed it.
- **Kept SwiftTerm** as a dependency: still used by the embedded shell terminal (`TerminalPanel`/`TerminalDrawer`), which has correct lifecycle (PTY close + `killpg` + `waitpid` reap + `willTerminate` + reconcile, proven by the selftest).

## Issues
- macOS has no `PDEATHSIG`, so children survive parent death unless explicitly killed — this is why every long-lived spawn needs an explicit `willTerminate`/stop hook. Fast user switching compounds it: both users' sessions stay fully resident in RAM, so orphans linger under memory pressure.
- Embed-mode nvim (and `claude`) **ignore SIGTERM** — the orphans only died to `kill -9`. Hence the SIGKILL escalation in `ShellRunner.stop()` matters, not just SIGTERM.
- The `git add` for commit 1 aborted on the already-`git rm`'d path (`fatal: pathspec … did not match`), silently dropping the two comment edits from the commit. Caught it in verification; fixed with a `git reset --soft` + clean re-commit. Lesson: don't re-`add` a path that's already staged-as-deleted in the same multi-path `add`.

## What to remember
- The audit found the surviving codebase is otherwise clean: no `dismantleNSView` anywhere, but every remaining `NSViewRepresentable` either holds no OS resource or reuses a stored view (WKWebviews are reused + navigated, not recreated per selection). The nvim spawner was unique in spawning its own process inside the representable.
- One residual hardening item, not fixed (fragile-pattern, not an active leak): `ProductWebView` adds a `WKScriptMessageHandler` with no `removeScriptMessageHandler` — safe today only because the webview is reused and the coordinator holds `weak webView`.

---

## Commits
- df20aa5 Fix subprocess leaks: kill agents on quit, honor process-group kill
- 4ca5586 Remove dead nvim EmbeddedTerminal spawner
