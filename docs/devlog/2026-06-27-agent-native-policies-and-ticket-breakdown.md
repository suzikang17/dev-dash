---
lore_type: devlog
created: 2026-06-27
title: "Agent-native policies + ticket breakdown"
date: 2026-06-27
day: 10
---

**Added a `policy` lore type and a ticket→task breakdown feature that reads its behavior from policy docs — plus a manual-status/draft state for task-less tickets.**

## What got done
- **Manual status + draft state for task-less tickets** (`LoreTasksView`): empty tickets show a "draft" pill instead of a misleading `0`, and get a context-menu status picker (wiring up the previously-dead `TicketStore.setStatus`). Tickets with tasks keep deriving status from the rollup (with a disabled "Status rolls up from tasks" note).
- **New `policy` lore type** (`docs/.lore/types/policy.schema.yaml`, `docs/policies/0001-ticket-breakdown.md`): agent-behavior policies as data, with frontmatter (`applies_to`/`trigger`/`status`/`priority`) used for routing.
- **`PolicyStore`** reads policy docs (reusing `TaskStore.parseTaskFrontmatter`; `parseList` splits comma values, tolerates brackets/scalars). **`DashboardStore.policies(for:appliesTo:trigger:)`** returns active, scope+trigger-matched policies ordered by `(priority, id)`; `reloadPolicies` runs at project-scan sites.
- **Ticket breakdown**: `buildTicketBreakdownPrompt` + `ticketPolicyText` inject the active policy body into a `suggestTasksForTicket` run (`claude -p`, parsed via the existing `parseSuggestedTasks`); `launchClaudeForTicket` also injects the `on_work` policy (gated on `task.ticket`). UI: ticket context-menu "Break into tasks" / "(read code)" → inline checklist review in the expanded ticket → accept writes child tasks.
- New `PolicySelfTest` (`--selftest-policy`): 18 headless checks (read round-trip, query filter/order, prompt assembly).

## Decisions
- **Policy behavior lives in a lore `policy` type the app injects into prompts**, not in the lore schema `prompt:` (wrong scope + app bypasses `lore add`) and not as project CLAUDE.md prose (advisory, off-pattern). See ADR 0012.
- **Multi-value frontmatter as comma-separated strings**, because `lore` has no list/int field type — matches the existing `task` schema `phases` convention.
- **No auto-breakdown on ticket create** — it would fight the draft state and spend tokens on stubs. On-demand + review instead.

## Issues
- The plan originally specified `type: list`/`type: int` and `[bracket]` frontmatter; `lore validate` rejected it. Corrected mid-execution to `type: string` + comma values (the Task 1 implementer had already adapted correctly). Fixed plan + spec to match.
- `EnterWorktree` branched from `origin/main` (the `worktree.baseRef` knob is a Claude Code setting, not git config), missing local commits; fixed by fast-forwarding the worktree branch to local HEAD.

## What to remember
- `lore` decision type is `decision` (singular) for reindex/validate, not `decisions`.
- Cross-file "Cannot find PolicyStore/Policy in scope" SourceKit errors during this work were stale-index noise — `swift build` was always clean.
- Minor cleanups deferred to final review: `reloadPolicies` is over-called on ticket-mutation paths (`addTicket`/`setTicketStatus`/`setTicketOwner`) where policies never change.
- Built on branch `worktree-ticket-breakdown-policy` (worktree), separate from an unrelated in-flight iOS-simulator-preview feature left uncommitted on main.

---

## Commits
- df7695e feat(lore): add policy doc type + ticket-breakdown policy
- 4fa50d2 fix(plan): policy frontmatter uses comma-joined strings (lore has no list type)
- 1610ad2 feat: PolicyStore reads policy lore docs (list-field parsing)
- 73b77f0 feat: DashboardStore policy loading + scope/trigger query
- 752e9ae feat: ticket-breakdown prompt builder + policy-text injection
- decfd6e feat: suggestTasksForTicket + on_work policy injection on launch
- 50195bd feat: ticket context-menu breakdown + inline suggestion review
- d9fcdb0 feat: manual status + draft state for task-less tickets
