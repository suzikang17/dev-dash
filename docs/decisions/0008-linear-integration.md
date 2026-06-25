---
lore_type: decision
title: "Linear integration: two-way sync via personal API key, per-group team binding"
date: 2026-06-24
category: architecture
revisit: false
---

## Why this choice

Dev-dash needs to surface Linear issues alongside local tasks without requiring a
separate OAuth dance or a server-side component. A personal API key stored in the
macOS Keychain satisfies the auth requirement with zero infrastructure, matching
how the Vercel integration piggybacks on the CLI token.

Two-way sync is preferred over read-only because status changes made in dev-dash
(kanban drag, mark done) are real decisions that should propagate back — otherwise
Linear becomes an out-of-date shadow of the local state.

Linear teams and projects naturally span multiple repos (e.g. a "Platform" Linear
project covers both the API and the CLI repos). Binding Linear at the **group**
level rather than per-repo eliminates duplicate issue fetches and keeps the sidebar
hierarchy legible.

## Decision

- **Auth**: a single personal API key per user, stored under service
  `com.suki.devdash.linear` / account `personal-api-key` via `SecItemAdd` /
  `SecItemUpdate`. No OAuth, no server.
- **Project Groups**: `ProjectGroup` (persisted at `~/.devdash/groups.json`) is the
  unit of Linear binding. Each group has one optional Linear team + optional project
  filter, and a set of repo paths. One repo belongs to at most one group.
- **Group task cache**: fetched Linear issues are stored per-group at
  `~/.devdash/group-tasks/<groupId>.json` (not per-repo). `GroupStore` manages
  reads, writes, and deletes with atomic file writes.
- **Read path**: `LinearScanner.fetchIssues(teamId:projectId:)` hits the GraphQL
  endpoint and returns up to 100 issues. Issues are merged (upsert by `linearIssueId`)
  into the group cache; the cache is never destructively cleared.
- **Display path**: `DashboardStore.tasksForDisplay(projectPath:)` merges the
  repo's own local tasks with the group's shared Linear task cache. The sidebar
  and kanban boards call this method instead of the raw `projectTasks` map.
- **Write path**: `DashboardStore.setTaskStatus` routes `.linear` tasks through
  the group that owns them, fires a detached `Task` to resolve the workflow-state
  ID and call `issueUpdate`. The UI is never blocked; local state wins on failure.
  A `pendingLinearPush` guard prevents remote status from overwriting a locally
  pending change during the next sync cycle.
- **Migration**: at init, `migratePerRepoLinearBindings()` scans `projectMeta` for
  any legacy per-repo `linearTeamId` fields, creates matching groups (keyed on
  `linearProjectId ?? linearTeamId` to deduplicate), migrates repo paths into
  those groups, and clears the per-repo fields. One-time, idempotent.

## Sidebar & settings

- The `.projects` sidebar tab shows groups first (sorted by creation date), each
  as a collapsible `CollapsibleGroupSection` with a Linear badge when bound. Repos
  not in any group appear underneath as ungrouped folder sections.
- `LinearSettingsView` replaces the old per-project `ProjectBindingRow` with a
  `groupsSection` listing all groups. Each `GroupSettingsRow` supports inline
  rename, Linear binding (team + optional project picker), and per-member removal.

## Workflow-state type mapping

Linear's `type` field on workflow states is mapped to `TaskStatus` as follows:

| Linear type | TaskStatus    |
|-------------|---------------|
| `triage`    | `.open`       |
| `backlog`   | `.open`       |
| `unstarted` | `.open`       |
| `started`   | `.inProgress` |
| `completed` | `.done`       |
| `canceled`  | `.skipped`    |

For the reverse mapping (TaskStatus → Linear state), the lowest-`position` state
of the matching type wins. `.open` prefers `unstarted` over `backlog` over `triage`.
`.blocked` maps to `started` (Linear has no blocked type; this keeps the issue
in an active column).

## Rate-limit / caching rationale

Linear personal keys are limited to ~1 500 req/hr. Workflow states are cached in
`LinearStateCache` (actor, 5-min TTL) because they change rarely and are fetched
on every status push-back. Issue fetches run once per group during `refreshAll()`'s
fan-out (default 15-second poll) — not per-repo, not on every render. Teams and
projects are fetched on-demand from the Settings UI only.

## Known limitations / follow-ups

- A permanently-failing Linear status push (network error, permission denied) leaves its `pendingLinearPush` entry indefinitely with no retry or expiry, masking the remote status for that task until relaunch. Acceptable for now; retry-or-expiry is a follow-up.
