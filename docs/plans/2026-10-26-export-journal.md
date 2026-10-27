---
artifact_readiness: implementation-ready
execution: code
---
# Export journal writer (#6319)

Source: `docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R2/tickets/MP-R2-C6-T02.md`.

The approved design already fixes scope. Implement one optional final supervision child,
with a caller-process reader. Reuse Events.Journal, Envelope, InstanceId and JsonStore.
Retention and durable consumers remain separate tickets.

1. Add `src/lib/aiur/events/export.ex` and `export/{layout,exporter,reader}.ex`.
   Layout owns numeric segment ordering, bounded replay, metadata and permissions.
   Recover sequence from segment records; metadata is a cache, but epoch is retained.
   Subscribe before writing the start gap; publish status only after durable append.
   Fail closed on corruption or I/O failure, reporting once per process boot.
2. Wire the exporter after the current final child through an application-owned
   callback module. Extend `src/lib/aiur/id_floor_sources.ex`, the catalog and
   `components/event-bus.json`; update existing configuration and message-bus docs.
3. Add `src/test/aiur/events/export/{exporter,reader,wiring}_test.exs` covering dense
   sequences, reboot gaps, identity failure, corruption without mutation, append failure,
   torn-tail reader safety, segment rollover, process-independent status, filtering,
   final placement, disabled gating and ID floors. Run affected callers as well.

Risks: meta may lag a durable append; recover from journal. Readers may see a partial
append; never repair or expose records beyond the published durable head. Validate dense
sequence across retained segments and reject malformed complete records. Avoid introducing
identity/signal/PubSub compile edges into event-bus internals. Keep new modules under 300 lines.

Validation: focused ExUnit with four cases, compile/format/lint, structural and handoff
gates. Mutation-check new tests in an isolated clean worktree. CLI smoke is a post-deploy
Executor-root check because agent workspaces cannot launch the destructive sandbox run.
