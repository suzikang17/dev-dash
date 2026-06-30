---
lore_type: task
title: Persist the hook event bus as an append-only NDJSON operation log
status: open
owner: ai
category: engineering
priority: high
effort: small
created: '2026-06-30'
ticket: '0008'
---
Persist the live hook event stream (currently `DashboardStore.recentEvents`, in-memory,
300-capped) to a durable append-only log so the agent operation history survives the
session. NDJSON is the source of truth per ADR
[[0013-durable-agent-operation-log-jj-anchors]].

## Acceptance criteria

- [ ] Add a `Codable PersistedEvent` mirror (ISO-8601 `ts`, stable `id`, `session` parsed
      from the hook payload, `cwd`, `hook`, `cat`, `detail`) — do **not** serialize
      `ClaudeIntegrationEvent` (not Codable; id/timestamp are construction-time).
- [ ] `DashboardStore.handleHookEvent` appends one NDJSON line per event to
      `<projectPath>/.devdash/events/<YYYY-MM-DD>.ndjson` *after* project matching, off
      the main thread.
- [ ] Events with no matched project append to `~/.devdash/events/_unmatched.ndjson`.
- [ ] `recentEvents` reconstructs as a tail view over today's file on launch.
- [ ] Append is crash-safe (`seekToEnd`, no read-modify-write) — verified by a
      write / kill / reopen test.

## Notes

`.devdash/` is already gitignored, so the log is excluded automatically. This is the
write side only; the query view is task 0009.
