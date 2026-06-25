---
lore_type: decision
title: "Bundle lore with the app (CLI, not a Swift dep) to keep app↔lore compatible"
date: 2026-06-25
category: architecture
revisit: true
---

## Why this choice

dev-dash and lore must agree on the doc format. The agreement has two sides:
- **dev-dash's Swift doc-adapters** (`TaskStore`, `TicketStore`, `ArtifactStore`) — compiled INTO the app, so they're always the app's version.
- **the `lore` CLI the launched Claude sessions run** (`lore add ticket`, `set-status`, …) — whatever is on `PATH`, which can drift from the app.

Compatibility breaks only when the `lore` on PATH differs from the version the app was built/tested against (e.g. a shipped app on a machine with an old or absent lore). So the fix is to let the app **control which lore the agent runs** by shipping a matched copy.

This is NOT a Swift runtime dependency. lore stays a portable Node CLI the agent invokes; the app just owns the copy. (lore is JS — bundle the built `dist`, assume `node` is present; do not ship a Node runtime.)

## Decision

1. **`dist.sh` bundles lore's built `dist/` into `DevDash.app/Contents/Resources/lore`** — a snapshot of the exact version the app was built/tested against.
2. **dev-dash resolves `lore` to the bundled copy** — extend `LoreRunner`'s binary resolver to prefer `Bundle…/Resources/lore/bin/lore.js`, and **prepend its dir to the embedded terminal's `PATH`** so launched `claude` sessions run that lore.
3. **Version stamp + compat check** — record the bundled lore version; surface it (Settings/Info) and warn if a different `lore` shadows it, so drift is visible.
4. **Dev stays live** — `run.sh` keeps using the `~/dev/lore` symlink so both repos are edited in lockstep; only `dist.sh` snapshots the bundle.

## Options considered

- **Bundle the CLI + app resolves to it (chosen)** — guarantees the agent's lore matches the app's Swift adapters; no Node Swift dependency.
- **Make lore a Swift/runtime dependency / rewrite in Swift** (rejected) — heavy, and the agent needs a portable CLI on PATH regardless; dev-dash already does its own doc ops in Swift, so it doesn't need lore at runtime.
- **Keep lore fully separate, global only (status quo)** (rejected for ship) — fine while both repos are local, but offers no compatibility guarantee once distributed.

## Tradeoffs

- Gain: app and the agent's lore ship as a matched pair — no drift after distribution; zero separate-install step for users.
- Give up: `dist.sh` complexity; still assumes `node` present; two implementations of the doc format remain (Swift adapters + lore JS) — bundling pins the CLI version but doesn't collapse the dual implementation (managed via the schema-as-contract + the `--selftest-taskstore` guard on the Swift side).

## Timing

This bites only at **distribution / running where `~/dev/lore` isn't** — not in the current dual-local-repo dev setup, which is already lockstep. Build it as part of packaging. The cheap interim, buildable anytime: the **version-compat check** (record expected lore version, warn on mismatch) so drift is at least visible immediately.
