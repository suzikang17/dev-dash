---
lore_type: devlog
created: 2026-07-04
title: "NDJSON operation log (task 0007)"
date: 2026-07-04
day: 17
---

**Shipped the durable NDJSON operation log (ADR 0013 write side): every hook event now persists to `<project>/.devdash/events/<date>.ndjson`, with crash-safe appends and launch-time tail restore.**

## What got done
- `PersistedEvent` — Codable mirror (`ts` ISO-8601, stable `id`, `session`, `cwd`, `hook`, `cat`, `detail`); the non-Codable `ClaudeIntegrationEvent` view struct is never serialized.
- `EventLogStore` (Scanners/) — append-only NDJSON writer on a serial utility queue (off-main + ordered), `seekToEnd` + single write, never read-modify-write. Unmatched-project events → `~/.devdash/events/_unmatched.ndjson`.
- Torn-tail healing: if the file doesn't end in `\n` (killed mid-write), the append terminates the torn line first — only the torn event is lost; readers skip malformed lines.
- `DashboardStore.recordEvent` appends after project matching; `recentEvents` (300-cap) is now explicitly the tail view, reconstructed from today's per-project files once on launch (live events win over history).
- `EventLogSelfTest` (`--selftest-eventlog`): 15 checks — round-trip, unmatched routing, write/kill/reopen crash test, async ordering + flush. All pass; taskstore/policy suites unaffected.
- Task 0007 → done via `lore set-status` (dogfooding the agent write path); all 5 acceptance criteria checked off.

## Decisions
- Append hardening beyond the ADR: a 1-byte tail probe (not read-modify-write) to heal torn lines, so a post-crash append can't merge into the fragment and get lost with it.
- `flush()` (queue.sync) exposed for tests/shutdown rather than making appends awaitable — fire-and-forget stays the production contract.

## What to remember
- Write through `EventLogStore` only; the log is an observability surface — errors are swallowed, never block the event path.
- Task 0009 (SQLite query view, regenerable by replaying the NDJSON) and jj op-id stamping are the remaining halves of ADR 0013.

---

## Commits
- 237eea0 feat: durable NDJSON operation log for the hook event bus (ADR 0013, task 0007)
