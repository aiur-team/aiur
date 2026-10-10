---
title: Feature label projection and reconciliation
artifact_readiness: implementation-ready
---

# Feature label projection and reconciliation

Implement #3129 against the merged Features and History APIs. The registry remains authoritative; History supplies all observations, without new GitHub reads. CLI, intake tooling and rendering remain successor work.

## Implementation units

1. Pure rules in `src/lib/aiur/build_order/features/label_rules.ex`: validated slugs, provenance, conflicts, held/imported members, removal tombstones and the 120-second observation settle window. Test the decision table in `src/test/aiur/build_order/features/label_rules_test.exs`.
2. A leaf GenServer in `src/lib/aiur/build_order/features/label_projection.ex`, with small persistence/writer helpers in the same directory. Subscribe to registry and History, rebuild lost state from journal and observations, expose status/member states/retry/backfill release, and count ensure plus writes against minute/hour buckets. Test real registry/History integration with a scripted tracker and injected clock in new projection test files. Wire through `src/lib/aiur/build_order/component.ex`, the current component boot facade.
3. Add feature routing to `.claude/skills/aiur-build/scripts/validation_github_labels.py` and `validation_header.py`; cover drift and `feature:todo` in collected Python tests. Update `website/docs-app/apis/github.md`.

## Verification and risks

Run scoped compile, format, tests, lint, bare-receive and structural gates. Mutation-check new tests in an isolated worktree. Review persistence failures, stale/incomplete observations, race conflicts, backfill release, restart, tombstone recovery, pauses, unsupported trackers, terminal errors and both pacing limits. Manual sandbox verification belongs to the Executor; agent workspaces cannot launch the destructive test harness. This writer has its own hourly cap; it cannot enforce a joint cap with the build queue. Claim no saving.
