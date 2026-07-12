# Coach in the dev-dash wiki view — design

Approved 2026-07-12 (drawer-session shape chosen over rendered check-in page
and ambient strip).

## Entry point
A Coach menu (`figure.mind.and.body`) in the Docs-tab reader toolbar, shown
only when `project.framework == "Wiki"`. Items seed the session's opening
move: Check-in (default), Goal design, Gut-check, Season review.

## Launch mechanics
`DashboardStore.openCoachSession(projectPath:mode:)` mirrors
`openClaudeForDoc`: writes a prompt file to `~/.devdash/launch/coach-<ts>.txt`
that asks the session to run the `/coach` skill in the requested mode, selects
the project, opens the terminal drawer, sends `claude "$(cat …)"`. The skill
owns its context loading and coaching contract; dev-dash injects only the mode.

## Feedback loop (all pre-existing behavior)
Hook events light the wiki row's live-session dot; wiki writes from the
session live-reload the Docs view via NotesFileWatcher.

## Error handling
Same surfaces as Edit-with-Claude (runner failures); the skill itself handles
a missing wiki.

## Testing
No data-layer change → no selftest suite. Verification is a driven flow:
Coach button visible on wiki projects (verified by screenshot 2026-07-12);
menu-click launch shares the exact Edit-with-Claude mechanism. SwiftUI Menu
is not reliably reachable via AX scripting — manual click is the check.
