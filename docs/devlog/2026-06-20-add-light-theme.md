---
lore_type: devlog
created: 2026-06-20
title: "Add light theme"
date: 2026-06-20
day: 3
---

**Shipped a light/dark theme toggle, persisted across launches, reachable from a new settings modal and the command bar.**

## What got done
- Added an `AppTheme` enum (`.dark`/`.light`) in `DashboardStore` with `colorScheme`/`label`/`icon`/`toggled` helpers, a persisted `appTheme` (`UserDefaults["devdash.theme"]`), an `isSettingsVisible` flag, and a `toggleTheme()` method.
- Replaced the hardcoded `.preferredColorScheme(.dark)` in `App.swift` with `.preferredColorScheme(store.appTheme.colorScheme)`; added a settings sheet and a ⌘, shortcut next to the existing ⌘K.
- Built a new `SettingsView` modal with an Appearance section (two tappable Dark/Light cards with accent-bordered selected state), structured via a reusable `section()` helper for future settings.
- Added command-bar commands: typing theme/light/dark/appearance/mode surfaces "Switch to … theme"; typing settings/preferences/config surfaces "Open settings".

## Decisions
- Simple two-state toggle (Dark/Light), no "follow system" option — matches the requested behavior and keeps the persisted value unambiguous.
- Scoped the commit to the four theme files only, leaving the in-progress `onSaveLore` spike (ProductTabView/ProductWebView/HTML) uncommitted.

## Issues
- A transient incremental-compile error surfaced in `ProductTabView.swift` (the uncommitted `onSaveLore` spike) during the first build; a full rebuild was clean — it was stale-index noise, not a real error in that file.

## What to remember
- The app was only dark-locked by a single line; most views already use semantic colors and the HTML docs ship a `prefers-color-scheme: light` palette, so the WKWebView and views adapt automatically once `preferredColorScheme` flips. No mass color refactor was needed.
- Theme preference key is `devdash.theme`; default is dark when unset/invalid.

---

## Commits
- 233c7c2 add light theme with light/dark toggle, settings modal, and command-bar commands
