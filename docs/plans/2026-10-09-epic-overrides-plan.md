---
title: Epic override registry and batch CLI
date: 2026-10-09
execution: code
artifact_readiness: implementation-ready
---

# Epic override registry and batch CLI

Implement #3127's local, journaled general-epic assignments. The merged resolver
is `Aiur.BuildOrder.Epic`; the merged catalog is `build_order.general_epics`
(`GeneralEpic`), replacing the research's proposed schema names.

## Persistence

Add `src/lib/aiur/build_order/epic_overrides.ex` and small journal/record modules.
Serialize batches through one GenServer, publish a protected ETS snapshot only
after atomic fsynced persistence, and retain an append-only set/clear journal.
Use `Aiur.Fs.atomic_write/3`, `ProviderHealth`, and instance-scoped Config.Paths.
Do not quarantine or reset unreadable evidence. Validate the catalog on writes,
ids/provenance, journal sequences, repository, size and regular-file safety.
Add the supervised store and component ownership; keep oversized files no longer.

Test in `src/test/aiur/build_order/epic_overrides_test.exs`: atomic invalid
batches, deduplication, no-ops, provenance changes, concurrent replacement,
clear/restart/generation, corrupt/newer/foreign/unsafe files, not-running reads,
failed persistence, permissions, cap, PubSub, config reload/errors and safe init.
Add the path test to `src/test/aiur/config_paths_test.exs`.

## Entry points

Add `src/lib/aiur/epic_cli.ex`, shared engine parsing/dispatch/help, guarded
AgentControlCLI delegation, and a dynamic Epic tool. Bind actor/default ids in
ToolExecutor through a small dedicated helper; reject caller-supplied provenance.
CLI show reports stored assignments, including unknown catalog status, never
resolver output. Update CLI and lifecycle docs in this PR.

Test CLI rendering/refusals in `src/test/aiur/epic_cli_test.exs`, shell parsing
with an RPC stub in a dedicated engine test, and tool validation/bound issue
identity in dedicated dynamic-tool tests. Update the advertised tool inventory.

## Verification and limits

Run compile, format, affected tests with max-cases 4, lint, bare-receive and
committed file-size gates. Mutation-check added tests in a separate clean
worktree and record commands/results. Self-review before ready PR targeting main.
No GitHub projection, UI, journal compaction, or confirm command. Manual CLI
harness runs are prohibited in agent workspaces; focused tests cover entry points.
