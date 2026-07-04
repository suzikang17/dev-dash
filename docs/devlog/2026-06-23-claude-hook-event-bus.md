---
type: devlog
title: "Day 6 — Claude Code hook event bus: live sessions, context injection, events feed"
date: "2026-06-23"
day: 6
phase: Tooling
---

**Made Claude Code a first-class citizen: a localhost hook event bus so any `claude` session (terminal/IDE/app-spawned) reports activity back to dev-dash, and dev-dash feeds task/devlog context into the session — built and reviewed in five stages.**

## What got done

- **EventServer.swift** — localhost-only `NWListener` (binds `127.0.0.1` only), token auth via `X-DevDash-Token` against a `0600` `~/.devdash/event-endpoint.json`, 1 MB body cap, per-connection 10s timeout, completion-based responses (no queue blocking). Port-probes 8730–8760.
- **HookInstaller.swift** — writes `~/.devdash/bin/devdash-hook` (pure-`sed` JSON parse, no python3 dep) and merges hook entries into a project's `.claude/settings.json` non-destructively; refuses to write (and backs up) if the existing file is unparseable.
- **Live sessions** — external `claude` sessions surface as live cards in the Claude tab (file activity + current tool) and a green dot on the sidebar project row; abandoned/ended sessions pruned by a periodic sweep.
- **Auto-devlog on `SessionEnd`** (opt-in, default off) — summarizes meaningful sessions via `LoreRunner`; gated behind a five-condition guard so it never spawns `claude` on read-only sessions or when off.
- **Git refresh** — `git`/`gh` mutations in a session trigger a debounced `GitDiffScanner`/status refresh.
- **Context injection** — open tasks + latest devlog injected into each session via `additionalContext` (built with `JSONSerialization`, exact `hookSpecificOutput` schema); a single unambiguous in-progress task is linked and advanced (hasAIRun + owner→human) on session end.
- **Settings UI** — per-project install/remove, behavior toggles, live server-status line.
- **Per-project events feed** — capped (300) in-memory log of every hook event, shown per project in the Claude tab with a "Show all" toggle for chatty per-tool events.
- **ADR 0004** — documents the architecture (localhost HTTP transport, per-project hooks, single bridge script) and the build stages.

## Decisions

- **Localhost HTTP bus over an append-only event file** — push, instant, and (critically) lets the server return `additionalContext` synchronously so the hook can inject it. The completion-based response refactor in stage 1 is exactly what made stage 4's injection drop in without a rewrite.
- **`Stop` ≠ session end** — `Stop` fires every assistant turn; only `SessionEnd` ends a session and triggers auto-devlog. Marking sessions ended on `Stop` (initial stage-2 approach) was a bug, corrected in stage 3.
- **Ingest deferred** — events are transient/reactive; Claude Code already persists transcripts to `~/.claude/projects/*.jsonl`, so durable "ingest" would be an *indexer*, not a re-store. Build the in-memory feed first; let it signal whether durable storage is earned.
- **Auto-devlog opt-in** — silently spawning `claude` when a terminal session ends is surprising, so it's default-off; context injection (no spawn) is default-on.

## Issues

- **Settings-as-container vs. project** — `ProjectScanner` only ever treated a configured folder as a *container* of repos, so adding dev-dash itself as a scan folder did nothing. Fixed: `scanRoot` now also emits the folder itself as a project when it has a detectable stack (trailing-slash-stripped path so it matches session cwds), with dedup in `scanAll`.
- **Adversarial review earned its keep** — across the five stages the separate code-review pass caught a `settings.json` data-loss overwrite, a latent semaphore deadlock, an unbounded session leak, a non-Gregorian-calendar filename corruptor, and a read-only-session AI-spawn crack — none of which broke the build.

## Verified

- Transport smoke test (curl == what the bridge sends): valid event → 200, wrong/missing token → 403, malformed → 400, body cap, context injection returns exact-schema `additionalContext` for a known project and `{}` for an unknown cwd. The only untested link is Claude invoking the hook (its documented job).
