# Subsystems feature use

Usage and raw recommendations are frozen research observations; challenged recommendations are continuing-researcher decisions and remain provisional until final synthesis. See the matching `raw/` feature and `challenges/` record for evidence and limits.

| ID | Feature | Observed use | Raw recommendation | Challenge |
| --- | --- | --- | --- | --- |
| subsystems-01 | Run telemetry recorder (writer, resource sampler, lifecycle events, retention) | heavy | simplify | pending |
| subsystems-02 | Telemetry reporting: dataset reducer, run summaries, HTML dashboard generator, timeline, GitHub enricher, `aiur analytics` CLI | occasional | simplify | pending |
| subsystems-03 | Analytics Python toolkit (analytics/: reduce, run-summary, build-report, cost-report, flake-report) | none-found | cut | overturned → merge |
| subsystems-04 | Usage envelope and headless usage adapters (token accounting intake) | heavy | simplify | pending |
| subsystems-05 | Usage ledger (canonical crash-safe raw usage store) | regular | merge | holds |
| subsystems-06 | Usage aggregate projection (queryable rollup of the ledger) | regular | merge | holds |
| subsystems-07 | Usage compaction (retention of the usage ledger into compacted blocks) | none-found | cut | holds |
| subsystems-08 | Pricing: price table, pricing windows, grouped usage scopes, cost report tasks | rare | simplify | pending |
| subsystems-09 | Provider account generation (opaque account identity for usage and meters) | rare | cut | overturned → simplify |
| subsystems-10 | Provider meters (plan/credit balance meters and `aiur usage`) | regular | simplify | pending |
| subsystems-11 | Model availability ledger (model-usage.json) for rate-limit fallback and provider gate | regular | simplify | pending |
| subsystems-12 | Model catalog and discovery (model/list probes, provider model sources) | occasional | merge | overturned → simplify |
| subsystems-13 | Decision lifecycle latency metrics | occasional | simplify | pending |
| subsystems-14 | Operator message wait log | none-found | cut | holds |
| subsystems-15 | Perf phase logger (aiur_perf lines) | occasional | merge | overturned → simplify |
| subsystems-16 | Current-run membership store | regular | simplify | pending |
| subsystems-17 | Current-run projections, outcome snapshot and run summary | regular | simplify | pending |
| subsystems-18 | Ticket activity projection, progress retention and progress ETA tracker | regular | merge | overturned → simplify |
| subsystems-19 | Supervision health monitor | regular | keep | pending |
| subsystems-20 | Saturation sentinel (CPU saturation crash diagnostics) | none-found | cut | holds |
| subsystems-21 | Daemon death forensics: crash-dump capture, BEAM-death watchdog, lifecycle journal, launcher self-halt watchdog | rare | simplify | pending |
| subsystems-22 | Daemon log file, run-log retention and boot marker | heavy | keep | pending |
| subsystems-23 | Per-issue run logs (IssueLog: github-<repo>.<n>.log / .events.log / .agent_events.jsonl) | regular | simplify | pending |
| subsystems-24 | Workspace transcript logs (logs/agent.ndjson and agent.md projection) | heavy | simplify | pending |
| subsystems-25 | Event publication log (daemon-owned event-publications.ndjson) | regular | keep | pending |
| subsystems-26 | Agent process spawn log (agent-processes.tsv) | none-found | cut | holds |
| subsystems-27 | Build gate (shared build/test slot leases for agent mix runs) | heavy | simplify | pending |
| subsystems-28 | Host-load admission / load governor (dispatch gates and capacity binding) | heavy | simplify | pending |
| subsystems-29 | Agent resource guard (trim synthetic load generators) | none-found | cut | overturned → merge |
| subsystems-30 | Process reaper and shutdown cleanup | regular | simplify | pending |
| subsystems-31 | Pause containment (agent process-group registration for pause/stop) | regular | merge | overturned → simplify |
| subsystems-32 | Workspace provisioning (create, hooks, checkout, git metadata, refresh, reconstruction, removal) | heavy | simplify | pending |
| subsystems-33 | Workspace ownership, cleanup and orphaned-worker reaping | heavy | simplify | pending |
| subsystems-34 | Remote SSH workers and Docker bootstrap image | none-found | cut | pending |
| subsystems-35 | Repo base warm checkout and prewarm (warm-base materialization and dispatch gate) | occasional | cut | overturned → simplify |
| subsystems-36 | Test sandbox reset (`aiur --test` / `--test3` three-ticket event-flow sandbox) | rare | externalize | pending |
| subsystems-37 | Upgrade notice (channel-aware update check) | rare | simplify | pending |
| subsystems-38 | Init wizard and scaffolding (`aiur init`) | occasional | simplify | pending |
| subsystems-39 | Environment variable schema, startup validation and global-config startup | heavy | keep | pending |
| subsystems-40 | Boot plumbing: Erlang distribution, PubSub boot sequencing, legacy launch-state adoption | regular | simplify | pending |
| subsystems-41 | RTK output-compression admission | none-found | cut | holds |
| subsystems-42 | Developer tooling compiled into the product (affected tests, test shards, specs check, lint/PR-body/workspace mix tasks) | heavy | externalize | pending |
| subsystems-43 | Agent workspace environment plumbing (scratch TMPDIR, command shims, bundled skills install) | heavy | keep | pending |
| subsystems-44 | Shared utility libraries (fs, jsonl, json store, yaml, os/shell escaping, path safety, redaction, external-content wrapper, periodic worker) | heavy | keep | pending |
| subsystems-45 | Durable daemon state layout (Config.Paths) and the per-subsystem checkpoint pattern | heavy | simplify | pending |
| subsystems-46 | Codex sandbox policy (writable roots) | regular | keep | pending |
