---
lore_type: idea
created: '2026-06-30'
title: Access Claude sessions from iOS (companion app)
status: parked
category: Remote
effort: large
---
# Access Claude sessions from iOS (companion app)

Work on features/bugs from your phone: attach to a remote Claude session from iOS. This is the capstone of [[0001-remote-dev-box-integration-manage-preview-sync]] and [[0002-access-any-claude-session-from-any-computer]] — iOS is just **another client** of the same host-addressable, tmux-backed session, so no new server concept is needed.

## It already half-works today

The session lives in `tmux` on a persistent host, so any iOS SSH client (Blink, Termius) can already `ssh host -t tmux attach` and show the live Claude TUI — **zero code**. Good enough to validate the workflow before building anything native.

## The integrated version (dev-dash iOS companion)

A focused iOS/iPadOS app that lists your hosts → projects → sessions and lets you tap to **Attach** (tmux) or **Resume** (`claude --resume`):
- **Terminal rendering:** `SwiftTerm` — a mature Swift terminal emulator that runs on iOS and macOS (so the Mac app and iOS app can share the terminal layer).
- **SSH:** a Swift SSH library — `Citadel` (pure-Swift, SwiftNIO SSH) or a libssh2 wrapper. Keys in the iOS Keychain / Secure Enclave.
- **Input:** an accessory key bar above the keyboard for `esc` / `ctrl` / arrows / tab — the Claude TUI needs these and iOS soft keyboards lack them (Blink/Termius do exactly this). Hardware keyboard on iPad is the ideal experience.
- iOS app suspension is fine: the session runs on the host in tmux, so backgrounding just detaches; reattach on foreground.

## Relationship to dev-dash

Likely a **separate iOS target / companion app**, not the macOS app recompiled — but it can share the `Host` model, session registry, and `SwiftTerm` layer. On-brand given dev-dash already builds/runs iOS apps.

## Acceptance criteria (MVP)

- [ ] From iOS, pick a registered host + session and attach to a live tmux-backed Claude session, rendered with SwiftTerm.
- [ ] Accessory key bar provides esc/ctrl/arrows/tab so the Claude TUI is usable.
- [ ] Reattaches cleanly after the app is backgrounded/foregrounded.

## Open questions

- Native SwiftTerm+SSH app vs a mobile-friendly web terminal (xterm.js over a websocket bridge) vs just leaning on Claude Code's own web/cloud app on mobile Safari — which is worth the build?
- How much UI to share between the macOS app and an iOS companion (shared Swift package?) vs keeping the iOS app deliberately thin (attach-only).
- Push notifications when a session needs input / finishes (so you can step away and get pinged)?
