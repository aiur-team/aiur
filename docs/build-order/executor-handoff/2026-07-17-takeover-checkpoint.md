## Takeover checkpoint (updated 2026-07-17 20:10 PDT)

This checkpoint supersedes every live-state paragraph below it. The previous
Executor is handing off; do not infer current runtime or ticket state from the
older narrative.

### Runtime containment and restart gate

Aiur is intentionally stopped. The former debug daemon reproduced two
overlapping provider turn IDs (`7d85041c…` and `7e02bf19…`) for #1237 in the
same workspace. `aiurdev pause 1237` interrupted only the turn still recorded
as active while the older Claude child remained alive, so the Executor stopped
the daemon rather than trust pause containment. #1237 subsequently passed exact
CI and two correctness passes, merged through PR #1243 as
`develop@6b6f167999d5b47415c1fb1e5e10f87fbd81a3bf`, and was explicitly closed
`agent:done`.

The canonical runtime checkout is
`/home/orangekid/github/aiur-runtime-develop`. It is on literal `develop`, one
commit behind `origin/develop@6b6f1679`, with only the machine-local
`.aiur/config` and `.aiur/model-usage.json` changes; preserve both. Its control
RPC reports no running Aiur node. Do not restart until #1247 lands. After that:

1. update the runtime checkout to exact `origin/develop` without discarding its
   machine-local files;
2. run `scripts/aiurdev build` first;
3. launch detached with `--debug --max-agents 15`, Claude Opus, and
   aiur-claude 1.1.0;
4. prove from durable logs and process census that a normal check-in produces
   only one provider turn/workspace writer, then one queued follow-up after the
   parent exits; and
5. keep #1246 Executor-owned while Aiur consumes other unblocked tickets.

### Immediate P1: #1247 single-writer checkpoint delivery

Worktree:
`/home/orangekid/github/aiur/.worktrees/fix/1247-single-writer-checkpoints`
on `fix/1247-single-writer-checkpoints`. Committed head is merge commit
`ea9b8d82` over feature commit `3bfebcdd`, with exact base `6b6f1679`. No remote
feature branch or PR exists yet.

Before independent review, the exact merged head passed 106 focused tests,
compile with warnings as errors, format, specs, strict Credo, Dialyzer, and
diff checks. A real aiur-claude 1.1.0 protocol probe also returned `-32003` for
a second active turn and observed exactly one started/completed turn.

Independent exact-head review found three actionable gaps:

- boundary-drain `-32003` still failed the durable item instead of restoring
  it;
- the broad active-turn guard also deferred blocker-critical digests instead
  of routing them through an explicit interrupt; and
- the Claude regression asserted only that an interrupt frame was written,
  not acknowledgement, parent termination, and exactly-once queued follow-up.

Seven files are currently modified and intentionally uncommitted. The repair
adds boundary-drain restore behavior and regression coverage, classifies
direct-blocker digests at enqueue time as explicit interrupts while preserving
`urgent="true"` framing, and adds a production-shaped Claude lifecycle test
that acknowledges interruption and proves exactly one durable follow-up after
the parent completes. `mix format` and `git diff --check` pass, but these
post-review repairs have **not** yet been compiled or tested. Run their focused
tests first, fix any failures, run the complete #1247 matrix/static gates,
commit, and obtain a fresh independent delta review before push/CI/merge.

A full-suite run on the prior compiled head used seed `388564` and was stopped
for this handoff after four unrelated signatures: Workspace reconstruction
missed a 100 ms rendezvous; `post_aiur_turn_markers/4` took 894 ms against a
500 ms wall-clock bound under load; OwnershipRunner ran `after_create` twice;
and OrchestratorDeactivate again lost `BranchRefStore.ready_unblock`. These are
evidence for #1246, not grounds to change #1247 product code.

### Executor-owned convergence queue

| Ticket | Exact local state | Remaining gate |
|---|---|---|
| #1099 / PR #1244 | Repair head `f63fcaa3` keeps the 1 Hz age outside `aria-live`; focused regression green. Prior pushed head `9d0e9c87` has 7/8 CI green and a browser-harness failure. | Push repaired head, classify browser failure against literal develop, fresh exact CI/review, land/close. |
| #1110 / PR #1234 | Local head `ab955134` contains the real TicketActivity/provider-restart reload. Review confirmed behavior but rejected sleep-based synchronization. The reviewer incorrectly claimed a mandatory 1,000-line threshold: the real CONTRIBUTING target is 200 lines and explicitly not a CI line-count gate. | Writer is replacing sleep with an explicit >=2 s handshake and should extract only a cohesive responsibility justified by the real one-responsibility/200-line guidance. Then push/review/CI/land. |
| #1130 / PR #1217 | Local head `d586780c` resolves byte ceiling and truncation diagnostics. Review found replacement backfill still defaults to the live callback when production omits `on_backfill_message`. | Writer is making backfill no-op by default and adding the production-shaped regression; then push/review/CI/land. |
| #1120 / PR #1239 | Exact remote/local `a4759944`; draft; all eight CI jobs green. | Real synthetic/manual acceptance, mark ready, land, close. |
| #1238 / PR #1241 | Exact remote/local `2c8499ec`; ready; all eight CI jobs green. | Independent exact-head review, merge-forward to current develop, fresh CI, land, close. |
| #1246 | Executor-owned Ad Hoc reliability audit; issue comment `5009600338` contains the newest incident packet. | Start after the direct queue is merged and Aiur is live; maintain the evidence ledger and do not dispatch through Aiur. |

At handoff, the active bounded writers are the #1099 accessibility repair
(already committed at `f63fcaa3`), the #1110 synchronization/decomposition
repair, and the #1130 backfill-callback repair. They were told not to push or
mutate GitHub/runtime. Inspect their final messages and worktree logs before
touching those files.

### Execution policy and preview

The next Executor owns #1247, #1099, #1110, #1130, #1120, #1238, then #1246.
Once #1247 lands, Aiur should run the other unblocked Build Order tickets in
parallel; defer review of Aiur-owned PRs until the direct queue is merged.
Preserve one writer per workspace, merge-forward after every develop advance,
qualify exact heads, and explicitly close issues merged to non-default
`develop` with `agent:done`.

The live preview is
`http://<dashboard-host>:4180/docs/build-order/plan-preview.html`. Source and
served copy must remain byte-identical. The 30-minute preview/capacity cadence
continues from this 20:10 PDT checkpoint, and user-facing labels must use GitHub
ticket numbers rather than internal Build Order IDs.
