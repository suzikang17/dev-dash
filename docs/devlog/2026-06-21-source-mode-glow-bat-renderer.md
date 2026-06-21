---
lore_type: devlog
created: 2026-06-21
title: "Source mode: glow + bat file renderer"
date: 2026-06-21
day: 4
---

**Replaced the Files tab's plain-text "Source" view with glow (markdown) and bat (code) rendering inside an embedded terminal, made it the default mode, and chased down a SwiftTerm palette bug that was wrecking the colors.**

## What got done
- Added `EmbeddedTerminal.sourceViewer(filePath:isMarkdown:)` that spawns `glow` for markdown and `bat` for everything else, theme-matched (`glow -s light/dark`, bat `GitHub`/`Monokai Extended`).
- Wired Source mode in `FilesTabView` to the terminal viewer with a plain-text fallback when the tools are absent; made Source the **first** picker item and the **default** mode.
- Generalized the nvim-only binary resolver into `resolveBinary(_:)`, adding `~/.nix-profile/bin` to the search paths.
- Installed `glow` + `bat` via `nix profile` (Homebrew's `/opt/homebrew` dirs weren't writable).
- Output is non-paged so SwiftTerm's own scrollback handles trackpad scrolling; scroll-to-top fires on process exit so docs start at the beginning.
- Narrowed the file navigator (idealWidth 220, min 140, draggable).

## Decisions
- **Embedded terminal pager over a static ANSI-parsed pane** — reuses SwiftTerm for styling/scrolling/theming, matching the existing nvim mode.
- **Non-paged output instead of `glow -p` / `bat --paging=always`** — an inner pager hijacks scrolling and only responds to the keyboard; letting SwiftTerm scroll is the native UX.
- **Standard `.xterm` 256-color ramp for the read-only viewer** — opt-in via `standardAnsiPalette`, leaving nvim/shells on the app-wide `.base16Lab` strategy.

## Issues
- **Washed-out text + dark-red code blocks (the big one):** the app configures SwiftTerm with `.base16Lab`, which builds the 232–255 grey ramp by interpolating background→foreground. On the light theme that *inverts* the ramp, so glow's indexed colors (`234` body, `254` code-bg) rendered backwards. Fix: set `Terminal.ansi256PaletteStrategy = .xterm` on the viewer before `startProcess`.
- **JSON wrapped at ~2 chars:** launching the terminal at `frame: .zero` made the PTY report ~0 columns, so one-shot renderers hard-wrapped. A first attempt to *defer* launch until layout broke loading entirely (SwiftUI doesn't call `updateNSView` on layout-driven resizes). Reverted to immediate launch with a real `1000×760` initial frame.
- **`COLORTERM=truecolor` was a red herring for glow** — glow's built-in styles emit fixed 256-color indices regardless; truecolor only helps bat. Kept it for bat.
- Two unrelated build errors (`onSearchLore`, `DocRegenCLI`) were stale incremental-compile noise / parallel WIP, not from this work.

## What to remember
- Anything rendering raw 256-color indices into one of these terminals depends on the `.xterm` ramp; the default `.base16Lab` will mangle it on light themes.
- Piping glow/bat to a non-TTY strips color — diagnose their real output with `script -q /dev/null <cmd>`.
- glow/bat resolve from `~/.nix-profile/bin` on this machine, not Homebrew.

---

## Commits
- 14c0caa Files: glow/bat-powered Source mode (default, scrollable)
