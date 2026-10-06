---
ticket_id: MP-E1-C9-T03
feature_id: MP-E1
chunk_id: MP-E1-C9
bucket: 2-platform
title: End-to-end acceptance (AC12) through aiurdev --test3, and a clean test reset
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T05, MP-E1-C3-T06, MP-E1-C3-T07, MP-E1-C4-T03, MP-E1-C5-T02, MP-E1-C6-T02, MP-E1-C9-T01]
prior_units: [U9]
prior_boundaries: [CLI #31]
prior_features: []
prior_findings: [MP-E1 AC12]
size_owner: n/a (test_reset.ex small change)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C9-T03 — Prove it in a real run

> **Plan refresh (wave 0).** Uses the AGENTS.md "Manual testing" recipe as of
> `45a290e3`. Must run from the **Executor repo root**: agent workspaces are
> blocked from `--test`/`--test3` (`scripts/aiurdev:727-739`); an agent that
> hits the guard stops and reports, it does not retry elsewhere.

## Identity and outcome

- Bucket 2, MP-E1, C9, T03. Plan AC12.
- **User value:** evidence that the queue keeps the pool supplied in the real
  CLI, not only in unit tests.
- **Deliverable:**
  1. Production change: `TestReset.reset_labels_command_args/1` also removes
     the queue marker, so re-runs start clean.
  2. A recorded end-to-end run with `tmux capture-pane` evidence.

## Dependencies and blockers

- DESIGN-E1 and every behaviour ticket listed in `blocked_by`.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/test_reset.ex:786-796` builds the remove list from
  `state_labels ++ paused_labels ++ required_rate_limit_fallback_labels`, then
  re-adds `agent:todo`; `--test3` resets the 3-ticket blocker chain
  (`scripts/aiurdev:685-712`); pinned ids in `.aiur-test-tickets.json`.
- Test: `src/test/aiur/test_reset_test.exs`.
- AGENTS.md recipe: wrapper tmux on socket `claude-driver`, read
  `aiur foreground tmux socket … session …` from the startup log, `send-keys`
  and `capture-pane` against the inner socket.

## Chosen design

Sequence (T1, T2 = the first two pinned tickets):

1. Launch: `tmux -L claude-driver new-session -d -s aiur-driver -x 220 -y 60 "bash -c 'unset TMUX; AIUR_DEBUG=1 exec mise exec -- ./scripts/aiurdev --test3 --max-agents 1' 2>&1 | tee /tmp/aiur-driver-startup.log; sleep 3600"`.
2. Immediately `scripts/aiurdev pause` (global pause survives until resume).
3. `scripts/aiurdev queue add T1 T2 --after T1 --queue e2e` → T2 is
   unclaimed and not ready → withdrawn to marker-only (C3-T05/OQ-7 path).
4. `scripts/aiurdev queue show --json` → T1 `promoted`, T2 `waiting`.
5. `scripts/aiurdev resume`; T1's agent runs; merge or close T1 completed.
6. Within one reconcile T2 gets `agent:todo`; the AgentList (pane `0.0`)
   shows T2's agent start. Capture `0.0` before and after.
7. Cleanup: `scripts/aiurdev stop`; `tmux -L claude-driver kill-server`.

## Implementation steps

1. `test_reset.ex`: add `Labels.queued_labels("agent")` to the remove list.
2. Run the sequence; attach captures and `queue show --json` outputs to the PR.

## Non-happy paths

If T1 cannot be completed in the sandbox in reasonable time, close T1 as
completed by hand (that is the trigger under test) and record it.

## Compatibility and rollout

Test harness only.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/test_reset_test.exs` "reset removes the queued marker" | argv contains `agent:queued` in `--remove-label` | the `test_reset.ex` change |
| Manual AC12 run | capture shows T2 agent row appear after T1 completes, with no Executor promotion command between | — (evidence) |

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/test_reset_test.exs
```

## Completion and handoff

- [ ] Reset change merged; AC12 evidence in the PR (captures, JSON, timestamps).
- Dependents: C9-T04 (measures during this run).
