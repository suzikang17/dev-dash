---
lore_type: decision
title: "Make Claude Code a first-class citizen via a localhost hook event bus"
date: 2026-06-23
category: architecture
revisit: true
---

## Why this choice

The goal is to do all AI-assisted development inside dev-dash, with Claude Code wired
into tasks, devlogs, and GitHub. Today the app relates to Claude in two disconnected,
one-directional ways:

1. **App-spawned `claude -p`** (`ClaudeRunner` → `ShellRunner.start` → stream-json).
   The app drives Claude; the only feedback is stdout parsed for `[PHASE:]` markers.
2. **Real terminal/IDE Claude Code sessions** — discovered only *after the fact* by
   `SessionScanner`/`NotesFileWatcher` tailing `~/.claude/projects/*.jsonl`. The app is
   a spectator reading a finished transcript, never a participant.

That split is the friction. "Claude isn't first-class" means the app can launch Claude
but Claude can't talk back. Everything is pull-based (15s `startAutoRefresh` polling).

The fix is a **return channel built on Claude Code's own hooks**. Hooks fire for every
session — terminal, IDE, or app-spawned — and carry `session_id`, `cwd`, and
event-specific data (`tool_name`/`tool_input`, `prompt`) on stdin. A hook command can
also emit `additionalContext` to inject app state back *into* Claude. This makes any
session an event source and dissolves the in-app vs. outside distinction. `cwd` is the
join key that maps a session to a project in `projects` with no extra plumbing.

## Options considered

- **Transport (Claude → app):** localhost HTTP server inside dev-dash (chosen, push,
  instant, supports synchronous context-injection responses) vs. append-only
  `events.ndjson` tailed like `NotesFileWatcher` (no networking, but indirect and can't
  return context to the hook synchronously).
- **Hook scope:** per-project `.claude/settings.json` (chosen — explicit, committed,
  app-managed via installer) vs. global `~/.claude/settings.json` (every session
  everywhere; broader but noisier) vs. both.
- **Hook wiring:** a single installed helper script (`~/.devdash/bin/devdash-hook`) that
  reads the live endpoint+token from `~/.devdash/event-endpoint.json` and curls the
  payload (chosen — stable hook config, app owns endpoint discovery) vs. baking the port
  into each settings.json entry (breaks when the port changes between launches).

## Tradeoffs

- Gain: Claude becomes bidirectional and event-driven. Terminal sessions light up the
  right project card live; `Stop`/`SessionEnd` advance linked tasks and auto-write
  devlogs; git/PR views refresh reactively instead of on a 15s poll; sessions can be
  fed current task/devlog context.
- Give up: a new long-lived localhost listener (`NWListener`) and a token-auth surface
  to maintain; per-project opt-in (each repo must have hooks installed); reliance on the
  current Claude Code hook payload schema, which can change (revisit flagged).
- Security: bind to `127.0.0.1` only, require a per-machine random token header, and
  ignore events whose `cwd` doesn't match a known project.

## Build stages

1. Event bus: `EventServer` (localhost listener + token + endpoint file), hook installer,
   per-project settings writer, `SessionStart` confirmation.
2. Session↔task linking via `PreToolUse`/`PostToolUse`/`Stop`/`SessionEnd`.
3. Auto-devlog on `SessionEnd`; git/PR refresh on `Bash(git*|gh*)` tool use.
4. Context injection via `UserPromptSubmit`/`SessionStart` returning `additionalContext`.
5. One-click install/remove UI in settings.
