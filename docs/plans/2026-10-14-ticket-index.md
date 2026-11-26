---
title: Shared build ticket index
execution: code
---

## Goal and boundary

Implement #3139's store-only ticket join, coalesced live diffs and local-day
history pages. The issue's complete contract is authoritative. No GitHub reads,
new polling, rendering, pack rows or estimates. General epic configuration uses
`build_order.general_epics`. Stack on #3138 while PR #4425 remains open.

## Implementation units

1. Core assembler: `src/lib/aiur/build_order/index.ex` with small adjacent modules
   for row projection, catalogue assembly, paging and store reads. Public resolver
   context preserves unknown inputs. Sections use now/history/plan/nq precedence;
   all open tickets remain represented. History completeness controls counts.
   Tests: `src/test/aiur/build_order/index_test.exs` and paging tests cover field
   ownership, N-in/N-out, unavailable/empty, closure causes, feature stats,
   catch-up ages, producer precedence, DST, midnight gaps and invalid days.
2. Shared process: `src/lib/aiur_web/build/index.ex` reads once per 250 ms burst
   in one monitored task, retaining the old snapshot during reads. Signals only
   dirty cached parts. Restart/config failure sends a resync marker, never a full
   snapshot broadcast. Tests: `src/test/aiur_web/build/index_server_test.exs` for
   40-signal bursts, no-op diffs, moves/removals, restart, failed and slow reads.
3. Source/wiring: `src/lib/aiur_web/build/index_source.ex`, default DataSource,
   final dashboard child in `src/lib/aiur/application/children.ex`, seam allowlist.
   Usage remains per connection; Index publishes public daemon changes on its tick.
   Locked subscriptions never load usage.
   Tests: source, application ordering and real LiveView mailbox bounds.
4. Parity: seed real temporary stores plus producer facts from frozen datasets,
   expose `/build-fixture/index-live`, compare supported fields for live/noqueue/
   newrepo in tests. Extend the source schema with open-ticket state/truncation.

## Risks and verification

The researched APIs moved: adapt to current History, PlannedRows.build/3 and
NotQueued outputs without rereading History. The Executor assigned the daemon tick and diff stream to this ticket: the Index
runs its own 10-second tick using Freshness.read_daemon/1 and push_daemon?/2.
Payload schema must accept the additive open_tickets source. Keep usage out of
shared state and broadcasts. Ignore unknown signals; preserve all failure causes.

Run focused affected tests with max-cases 4, compile/format/lint and repository
guards. Mutation/revert tests run in a clean isolated worktree. Before publishing,
run pre-pr and structural gates; keep the PR draft until the direct blocker merges.
Manual CLI verification requires Executor root and cannot run in this workspace.
