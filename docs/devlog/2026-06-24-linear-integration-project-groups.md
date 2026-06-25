---
title: "Day 7 — Linear integration + project groups (two-way sync)"
date: "2026-06-24"
day: 7
phase: Integrations
---

**Added a Linear (linear.app) integration with two-way sync, plus a first-class "group" concept so multiple repos can tie to one Linear project. A group *is* the Linear binding: it owns one team/project, renders as a collapsible sidebar section above the folder grouping, and its synced issues show in each member repo's task view. Status changes push back to Linear. Built, reviewed across four passes, then re-based onto a 25-commit-newer `main` after discovering the original worktree branched from a stale `origin/main`.**

## What got done

- **`LinearScanner`** — GraphQL client against `https://api.linear.app/graphql`. Personal API key auth (bare key header, no `Bearer` — verified against Linear's docs). Fetches teams/projects/workflow-states/issues; `issueUpdate`/`issueCreate` mutations; per-team workflow-state cache (actor, 5-min TTL) mirroring `IssueScanner`.
- **`KeychainStore`** — the account-wide personal API key lives in the macOS Keychain (`kSecAttrAccessibleWhenUnlocked`), never in JSON/UserDefaults/logs.
- **`ProjectGroup` + `GroupStore`** — first cross-project config: groups persist to a global `~/.devdash/groups.json`, and each group's synced Linear tasks cache to `~/.devdash/group-tasks/<id>.json`. A group is an ordered list of repo paths + one Linear binding.
- **Group-level sync in `DashboardStore`** — `refreshGroupLinearTasks` fetches a group's issues once and merges into `groupLinearTasks[groupId]`; `tasksForDisplay(projectPath:)` unions a repo's own tasks with its group's Linear board. CRUD (`createGroup`/`rename`/`delete`/`setGroupLinearBinding`/`addProjectToGroup`/`removeProjectFromGroup`) with one-repo-one-group enforced. `setTaskStatus` routes `.linear` tasks through a push-back to Linear.
- **UI** — Linear is its own **Settings side-tab** (alongside Claude): paste key → load teams → manage groups (create/rename/delete/rebind, member list). Sidebar renders Linear groups first (collapsible, `rhombus` badge) then the existing folder grouping for ungrouped repos; right-click a repo → *Add to Linear group*. The primary `LoreTasksView` gained a **"Linear — synced"** section so a member repo's bound issues are visible and status-changeable by default.

## Decisions

- **The group *is* the Linear binding** — see [ADR 0008](../decisions/0008-linear-integration.md). Not all repos bind; ungrouped repos stay folder-grouped and unsynced. Binding moved off per-repo `ProjectMeta` onto the group, so "many repos → one Linear project" is the default, not hand-maintained in N places. A migration auto-coalesces any old per-repo bindings into groups (idempotent).
- **Status maps to Linear's workflow-state `type`, not name/ID** — `.open→unstarted`, `.inProgress→started`, `.done→completed`, `.skipped→canceled` — so sync survives teams that rename columns; the concrete state UUID is resolved per-team at push time.
- **Shared Linear tasks stored once per group**, not mirrored into each member's `tasks.json` — no duplication, and push-back from any member works.

## Issues

- **Two-way-sync data-loss path (caught in review)** — the 15s poll could revert an un-confirmed local status edit. Fixed with a `pendingLinearPush` guard that protects a just-edited (or failed-push) task from being overwritten by a stale poll.
- **Concurrent group refresh race** — the same group could be fetched from several call sites and last-writer-wins would drop upserts. Fixed by reusing the existing `refreshing`/`refreshPending` coalescing pattern (`refreshingGroups`) and collapsing read-merge-write into a single main-actor hop, plus a stale-binding bail if the user rebinds mid-fetch.
- **Stale base branch (the big one)** — the feature was built in a worktree branched from `origin/main`, which turned out to be **25 unpushed commits behind local `main`**. Those commits had retired `.devdash/tasks.json` for a lore-backed `TaskStore`, rewritten Settings to side-tab nav, made `LoreTasksView` primary, and already used ADR 0006. A straight merge would have conflicted and been semantically broken. Re-based onto current `main`: ported the self-contained new files clean, re-fitted Settings/Sidebar/DashboardStore by hand, renumbered the ADR to 0008.
- **Invisible-by-default (caught in port review)** — the port first wired Linear tasks only into the old board view; on current `main` the default task surface is `LoreTasksView`, which bypassed it. Fixed by surfacing the Linear section directly in `LoreTasksView`.
- **Dead legacy push-back** — the lore `TaskStore` doesn't persist `linearIssueId`, so the per-repo `.linear` push-back path was unreachable; deleted it (group push-back is the real path).

## Verified

- `swift build` green on `main`; app builds, signs, launches via `run.sh`. Four `ce-swift-ios-reviewer` passes (Linear client → group logic → state/concurrency → port-onto-main), each with fixes applied.
- GraphQL queries/mutations validated against Linear's live schema; auth scheme, Codable null-tolerance, and migration idempotency confirmed in review.

## Picking up next session (live sync)

The one untested path is a **real Linear workspace** — everything to date is build + review, not a live round-trip. To resume:

1. **Settings → Linear** → paste a personal API key (linear.app → Settings → Security & access → Personal API keys) → **Load teams**.
2. **New group** → name it, pick a team (+ optional project); or right-click a repo → *Add to Linear group*.
3. Select a member repo → its task view shows the **Linear — synced** section. Toggle a task's status and confirm it lands in Linear.
4. **Watch for:** auth failures (key vs OAuth header), workflow-state mapping on teams with custom columns, and the known limitation — a permanently-failing push keeps its `pendingLinearPush` entry with no retry/expiry until relaunch (ADR 0008 follow-up).

Relevant code: `Scanners/LinearScanner.swift`, `Scanners/GroupStore.swift`, `DashboardStore.swift` (group sync + push-back), `Views/LinearSettingsView.swift`, `Views/Tabs/LoreTasksView.swift` (Linear section).
