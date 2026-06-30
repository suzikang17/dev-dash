---
lore_type: idea
created: '2026-06-30'
title: Remote dev box integration (manage / preview / sync)
status: parked
category: Remote
effort: large
---
# Remote dev box integration (manage / preview / sync)

Let dev-dash work against a remote machine, not just `~/dev` locally — manage a remote dev box over SSH, preview remote deployments, and (eventually) sync dashboard data across machines. Parked as a "someday" north star; capture now so the plan isn't lost.

## The key architectural seam

Nearly everything funnels through `ShellRunner.run/start`, and the scanners call explicit local binaries (`ProcessScanner` → `/usr/sbin/lsof`, plus git / `simctl` / `lore`). So the unlock is a **`Host` abstraction** (`.local` vs `.ssh(user@host)`) that `ShellRunner` and the scanners route through — remote commands become `ssh host -- <cmd>`. This is a central seam, not a rewrite. The other structural change is the data model: today a "project" is a local path; a remote project is a `(host, path)` pair, so `Selection` / the sidebar gain a host concept.

Auth stays simple by leaning on the user's `~/.ssh/config` + keys and the system `ssh` binary — no credential management in-app.

## What to build (three tracks, phased)

1. **Manage a remote dev box** (most valuable)
   - SSH terminal: the embedded terminal is already a PTY — run `ssh host` in it for an instant remote shell (cheap, high value).
   - Read-only monitor: run `lsof` / `git` / `tail` over SSH and reuse the existing parsers to show running services/ports, git status, and logs for the remote box.
   - Remote server lifecycle (harder): remote dev servers outlive the SSH session, so starting/stopping them needs `tmux` / `systemd` / `nohup` supervision rather than child processes.
2. **Preview a remote deployment** (easiest)
   - Preview already accepts a custom/production URL. Extend into first-class remote-environment monitoring (health, uptime, logs). Private ports need an SSH tunnel.
3. **Sync dashboard data** (biggest lift, do last)
   - Lore/tasks are already files, so **git gives partial sync for free**. The gap is canvas layouts + UserDefaults state. A real cross-device/web backend means a server + auth + conflict handling.

## Suggested phasing

SSH terminal → read-only remote monitor → remote server lifecycle → remote preview → data sync.

## Acceptance criteria (MVP = phase 1, first two steps)

- [ ] Can register a remote host (from `~/.ssh/config`) and open a terminal into it.
- [ ] Can see the remote box's listening ports / running dev services in the sidebar or a panel.
- [ ] `ShellRunner` + at least `ProcessScanner` are host-aware (route through a `Host`).

## Open questions

- How does a remote host appear in the sidebar/`Selection` model — a new top-level entity, or remote projects nested under a host?
- Persistent remote servers: standardize on `tmux`, `systemd`, or detect what's available?
- Is sync worth a backend at all, or is "commit lore/tasks to git" enough, leaving only canvas/UserDefaults unsynced?
