---
ticket_id: MP-R2-C4-T03
feature_id: MP-R2
chunk_id: MP-R2-C4
bucket: 1 (refactor)
title: Swap the temporary bus boundary test for MP-R1's checker rule, and run the packaging acceptance (full suite on the merge ref + real aiurdev --test)
status: blocked
blocked_by: [DESIGN-R2 §1, MP-R2-C4-T01, MP-R1-C1-T03, MP-R1-C1-T05]
prior_units: [U8, U9]
prior_boundaries: [BUS #10]
prior_features: [MP-R1 (C1 checker)]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C4-T03 — CI gate swap and packaging acceptance

## Identity and outcome

- **Bucket 1, MP-R2, chunk C4.** The last code-touching ticket of the
  behaviour-preserving chunks (C1–C4).
- **Value.** (1) One gate instead of two: the event-bus boundary rules live
  in MP-R1's `scripts/check-components.py` in the required `lint` job, and
  the temporary ExUnit ratchet from C1-T06 is deleted. (2) Evidence that
  C1–C4 changed nothing a user sees (DESIGN-R2 §1 checkbox 1): full CI on
  the merge ref plus a real foreground `aiurdev --test` run per AGENTS.md
  "Manual testing — the only definition".
- **Deliverable.** A PR that deletes `src/test/aiur/events/bus_boundary_test.exs`,
  proves the checker covers every rule it had (fixtures), and carries the
  acceptance record in its body.
- **Non-goals.** No production change. If acceptance finds a regression,
  it is a bug in the C2/C3 ticket that caused it (DESIGN-R2 §1: "regressions
  found in review are bugs, not design changes"); file it and fix there.

## Dependencies and blockers

- **C4-T01** (entry final, ratchet zero), **MP-R1-C1-T03** (module-reference
  rules) and **MP-R1-C1-T05** (ratchet allowlist and CI wiring).
- DESIGN-R2 §1. Must run on a main that contains every C1–C3 ticket.
- Concurrent with C4-T05 (docs) and C5 tickets (inert).

## Verified starting point (45a290e3)

- Temporary gate (PROPOSED by C1-T06): `src/test/aiur/events/bus_boundary_test.exs`,
  two tests ("event-bus members reference only kernel, config, members, or
  recorded ratchet edges"; "every recorded ratchet edge still exists").
- Required `lint` job runs `make fmt-check`, `make lint`, and Python
  drift gates such as `python3 scripts/check-config-docs.py`
  (`.github/workflows/ci.yml:231-289`, step `:259-262`). MP-R1-C1-T01 adds
  `python3 scripts/check-components.py` there.
- Regression job runs `make regression` (`ci.yml:521-554`).
- Characterization suites from C1 (deliberately green on main):
  `issue_log_persistence_characterization_test.exs`,
  `out_of_order_id_witness_test.exs`,
  `executor_wake_gap_characterization_test.exs`,
  `exchange_restart_rebind_test.exs`, `placement_rule_test.exs`,
  `application_test.exs` (supervision order).
- Manual verbs: `aiur executor-wait [--timeout <s>] [--json]`,
  `executor-listen`, `executor-emit` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:469-472,3159-3184`);
  `aiur status` prints `WAKES CURSOR <n> PENDING <n>` (`src/lib/aiur/agent_control_cli.ex:2399`).
- `scripts/aiurdev --test` = single-ticket sandbox with debug and clear
  (`scripts/aiurdev:711`).

## Chosen design

1. **Rule parity before deletion.** For each assertion class of
   `bus_boundary_test.exs`, show the checker equivalent with a failing
   fixture in `scripts/test-check-components.sh` (MP-R1-C1-T06 harness):
   - a bus member referencing a private module of another component
     (e.g. `Aiur.Orchestrator.State`) → private-module rule fails;
   - a bus member referencing an L3 component at all (`Aiur.Orchestrator`)
     → layer rule (R-down) fails;
   - a stale allowlist row → MP-R1's ratchet must fail on a listed edge that
     no longer exists (if MP-R1-C1-T05 does not already enforce "no stale
     rows", add that to its fixtures through an MP-R1 request rather than
     keeping the ExUnit test).
2. **Delete** `bus_boundary_test.exs` in the same PR.
3. **Acceptance record** in the PR body (template below).

## Implementation steps

1. Add the event-bus fixtures to `scripts/test-check-components.sh`.
2. Delete `src/test/aiur/events/bus_boundary_test.exs`.
3. Run the automated checks below on the PR's merge ref (CI builds
   `refs/pull/N/merge`; reproduce failures there, not on the branch head).
4. Rebuild the dev release (`scripts/aiurdev build`) and run the manual
   acceptance from the Executor repo root (never from an agent workspace:
   `--test` is blocked there and resets sandbox tickets).

## Non-happy paths

- Checker cannot express "stale row" → keep a 20-line ExUnit test for that
  one assertion and say so; do not lose the property.
- Manual run: an agent row stays at `Warming up…` — wait (AGENTS.md
  precondition), do not conclude failure. A `QUEUED` chat message is
  success.
- `--test` guard message inside an agent workspace → stop and hand back to
  the Executor (AGENTS.md); never retry from `/tmp` or a copied harness.

## Compatibility and rollout

CI-only change. Rollback: restore the test file.

## Verification

Automated (CI required jobs green on the head SHA and merge ref):

```text
python3 scripts/check-components.py
bash scripts/test-check-components.sh
env -C <worktree>/src mise exec -- make fmt-check lint
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events test/aiur/executor_events_test.exs test/aiur/executor_listener_test.exs \
  test/aiur/executor_wake_inbox_test.exs test/aiur/orchestrator/auto_subscriptions_test.exs \
  test/aiur/orchestrator/event_topics_test.exs test/aiur/application_test.exs \
  test/aiur/agent_runner/bootstrap_digest_test.exs test/aiur_web/streamdeck_channel_test.exs \
  test/aiur_web/streamdeck_logs_test.exs test/aiur/webhooks
```

Plan acceptance criteria 2–4 hold: every pre-existing event test passes
unchanged in name and assertion (diff `git log --stat` of `src/test/aiur/events`
since `45a290e3` shows only additions plus the deleted boundary test).

Manual acceptance (AGENTS.md wrapper-tmux recipe, from the repo root):

```bash
tmux -L claude-driver new-session -d -s aiur-driver -x 220 -y 60 \
  "bash -c 'unset TMUX; AIUR_DEBUG=1 exec mise exec -- ./scripts/aiurdev --test' 2>&1 \
     | tee /tmp/aiur-driver-startup.log; sleep 3600"
# read AIUR_SOCKET / AIUR_SESSION from the "aiur foreground tmux socket" line
```

| Check | How | Expected (what the user sees) |
| --- | --- | --- |
| A. Agent receives a comment digest | Post an issue comment on the sandbox ticket as the operator account; open the agent's chat pane (`Enter` on its running row in `0.0`) and `capture-pane -p -S -200` on `0.1` | An incoming-event row for `ticket.<id>.issue.commented` and the agent reacting to the comment text |
| B. Agent receives CI terminal state | Wait for the sandbox PR's CI to finish | Incoming `ci.passed`/`ci.failed` row in the chat pane |
| C. Debug ticker | Agent list pane `0.0` with `--test` (debug on) | 💬 publish / 📬 receive marks for the above events (C2-T05 trace sink) |
| D. Executor wake | In a second shell: `scripts/aiurdev executor-wait --timeout 600 --json`, then trigger B or a PR open | `executor-wait` returns a wake naming the ticket and topic class |
| E. Executor journal | `scripts/aiurdev executor-emit executor.notify.release --payload '{"message":"r2-acceptance"}'` then `scripts/aiurdev executor-listen --topic 'executor.#'` | The emitted event is replayed with its id |
| F. Status | `scripts/aiurdev status` | `WAKES CURSOR <n> PENDING <n>` line present and unchanged in format |
| G. Executor message via TUI | Type a message into the `0.1` chat input, `Enter` | Message shows (or `QUEUED`), then delivered |

Paste the relevant `capture-pane` excerpts and command output into the PR
body. Cleanup: `mise exec -- ./scripts/aiurdev stop`;
`tmux -L claude-driver kill-server`.

Mutation statement: this ticket adds no test that guards a production
hunk; the fixtures guard checker rules and are shown failing by
construction (each fixture is a tree that must fail). The deleted test's
properties are listed with their checker equivalents in the PR body.

## Completion and handoff

- [ ] `bus_boundary_test.exs` deleted; checker fixtures cover its rules.
- [ ] All required CI jobs green on the head SHA (not only a narrow run).
- [ ] Manual checks A–G recorded with captures.
- [ ] DESIGN-R2 §1 owner confirmation can cite this PR as the "nothing you
      see changed" evidence.
- Docs: none in this ticket (C4-T05 owns `message-bus.md`).
- Dependents: C4-T04 (plan refresh), C5–C7 scheduling (RC-09).
