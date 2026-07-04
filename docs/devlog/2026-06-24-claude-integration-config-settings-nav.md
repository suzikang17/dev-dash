---
type: devlog
title: "Day 7 — Claude integration: per-project config, configurable events, settings side-tab nav"
date: "2026-06-24"
day: 7
phase: Tooling
---

**Turned the Claude Code hook integration from on/off into a real control surface — per-project behavior overrides, a configurable event set, a per-project events feed, a transparency panel, and a side-tab Settings nav — then confirmed it works end-to-end with a live `claude` session.**

## What got done

- **Per-project events feed** — capped (300) in-memory log of every hook event, shown per project in the Claude tab with a "Show all" toggle for chatty per-tool events. Recorded at the single `handleHookEvent` chokepoint, purely additive.
- **Scanner fix** — `ProjectScanner` now also treats a configured folder that is itself a repo as a project (not only a container of repos), so dev-dash added directly shows up; dedup by path.
- **"How it works" transparency panel** — `HookInstaller.hookSpecs` is now the single source of truth (event + firesWhen + reaction + gatedBy) driving BOTH install and a Settings disclosure, so the explainer can't drift from what's installed.
- **Per-project behavior overrides** — inject-context and auto-devlog became "global default + per-project override" via `ProjectHookConfig` (tri-state: nil=inherit). `effective*(for:)` resolve override ?? global at the event gates. Settings project list became an overview: live-status dot + recent-event count + tri-state menus.
- **Configurable event set** — which hook events get installed is now configurable (global default + per-project override). `installProjectHooks(events:)` reconciles (add enabled, remove disabled, preserve non-devdash). Global default falls back to all six when unset (no zero-install regression).
- **Settings side-tab nav** — replaced the single stacked scroll with a System Settings-style two-pane card (sidebar + content); Claude integration is its own tab.
- **Install intent** — `installedHookProjects` persisted set; `hooksInstalled` is now intent OR content, so "zero events enabled" is a legal installed state.

## Decisions

- **`nil`-means-inherit everywhere** — per-project overrides (behaviors and event set) store nil to inherit the global default, so the common case stays zero-config and only deliberately-forked projects carry explicit settings.
- **Reconcile-based install** — making install idempotent AND subtractive means every config change is just "re-run install with the effective set"; settings.json converges with no special-case add/remove paths.
- **Install intent separate from content** — "is this project managed" must not be inferred from "does settings.json currently have entries", because disabling all events legally empties the content. Persist intent explicitly.

## Issues

- **Empty-set trap (caught in review)** — disabling all events erased every devdash entry, so `isInstalled` went false and re-enabling silently no-op'd. Fixed via the install-intent set; `setEnabledEventsOverride` captures managed-state before mutating and re-reconciles on it.
- **Smoke-test false negative** — a real `claude -p` session first replied "NONE INJECTED". Instrumenting the bridge (`~/.devdash/hook-debug.log`) proved all four hooks fired and the server returned the `[dev-dash]` `additionalContext` — the model simply chose not to echo it. Delivery confirmed end-to-end; the bridge debug log is a handy diagnostic going forward.
- **Stale menu snapshot (review Low)** — the per-project/global event menus captured the set at body-eval and wrote it back; hardened to decide from the live store value inside the toggle closure.

## Verified

- Live `claude -p` in dev-dash fires SessionStart/UserPromptSubmit/Stop/SessionEnd hooks; server returns injected context for known projects, `{}` for unknown cwd; token auth (403), malformed (400), body cap all hold.
