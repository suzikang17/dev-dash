---
lore_type: idea
created: '2026-06-30'
title: Access any Claude session from any computer
status: parked
category: Remote
effort: large
---
# Access any Claude session from any computer

Make a Claude Code session stop being "a thing on this Mac" and become **addressable** — `(host, project, sessionId)` — so you can resume or attach to it from any computer and work on a feature/bug from anywhere. Builds directly on [[0001-remote-dev-box-integration-manage-preview-sync]] (the `Host` / SSH abstraction).

## Can one session be visible through multiple SSH connections?

Yes — the mechanism is a **terminal multiplexer on a persistent host**. Run Claude inside `tmux` (or `screen`) on the remote box:

```
ssh host -t 'tmux new -A -s claude-<project> claude'   # attach-or-create
```

Any number of SSH connections can then `tmux attach` to that same session and all see the **same live Claude TUI, mirrored in real time**. The session keeps running when every client disconnects (that's what makes "from anywhere" work), and you reattach later from a different machine. dev-dash's embedded terminal is already a PTY, so it can run exactly this attach-or-create command.

Two distinct flavors:
- **Live shared view** (simultaneous): `tmux attach` from N clients → mirrored live session.
- **Sequential resume** (across machines, not simultaneous): `claude --resume <id>` / `claude -c` — the transcript is persisted, so any client with access to the host/transcript can pick it back up.

## What to build

- A session registry keyed by `(host, project, sessionId)`; dev-dash from any client lists sessions on registered hosts and offers **Attach** (tmux) or **Resume** (`claude --resume`).
- Wrap launches so project Claude sessions run inside a named tmux session on their host (so they survive disconnects and are attachable).
- Reuse the existing session substrate: `SessionDigest`, live sessions via the event server + hooks, `SessionDetailView`, `ClaudeRunner`.

## Caveats

- tmux shares one PTY: all attached clients share input focus (fine for one person across devices; messy for true multi-user) and the view sizes to the smallest attached client.
- The session must live on a **persistent host** — i.e. this needs the remote-dev-box work (0001) to be real first.
- Alternative route: lean on Claude Code's own web/cloud sessions (claude.ai/code), which are already reachable from any browser — less SSH plumbing, but a different integration surface.

## Acceptance criteria (MVP)

- [ ] Launching a project's Claude session on a host runs it inside a named tmux session.
- [ ] From a second computer, dev-dash can attach to that live session and see it mirrored.
- [ ] Sessions are listed per host with Attach / Resume actions.

## Open questions

- tmux vs leaning on Claude Code cloud/web sessions — which is the primary path?
- How to reconcile dev-dash's local session tracking (event server + hooks) with sessions running on a remote host (do hooks phone home across the network)?
- Naming/discovery: one tmux session per project, per task, or per worktree?
