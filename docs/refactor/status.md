# Refactor Status

Last updated: 2026-07-08 00:35 PDT

## Current mode

Phase 1 is running again as a Sub-run A canary. Phase 0 blocker #768 (the Codex
`{:error, :unavailable}` crash) is fixed: PR #769 landed on `main` at
`bba7de26`, `main` was pulled into `v2` (`aa9d4cfe`), and full `make ci` from
`src/` passed (2392 tests). The root cause was a `MatchError` on the `:ok =`
orchestrator bookkeeping RPCs under Codex-exhaustion overload — not a `run_turn`
result — so the fix is an AgentRunner-only best-effort change to
`consume/restore/fail_delivered_queue_items`, which also unblocks the
pre-existing usage-limit pause.

#749 (T-001: RepoBase honors `tracker.base_branch`, CI push `+= v2`) was then
reviewed clean, update-branched, and merged to `v2` at `52d6c45a`, closing
#735. `v2` is now at `52d6c45a`.

The fleet was rebuilt from `v2` and relaunched with
`scripts/aiurdev --bg --debug`. Only #739 (rework of the #755 review) and #748
were unpaused; both are working on Codex with no `:unavailable`/crash churn.
Codex recovered (the 5-hour limit reset overnight), so tickets keep
`model:codex`; reroute to `model:claude` only reactively if an agent stalls on
a Codex limit. #740–#744 stay `agent:paused` for Sub-run B until the canary
proves out.

The dogfood `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, and
`.aiur/prewarm` are retargeted to `v2` on the `v2` branch.

## Resume notes

Phase 1 restart checklist:

1. Fix or explicitly clear #768 (Codex `{:error, :unavailable}` should pause,
   not crash/retry-loop).
2. If code lands on `main`, pull `main` back into `v2`.
3. Run `scripts/aiurdev build` from the `v2` checkout.
4. Relaunch with `scripts/aiurdev --bg --debug`.
5. Resume only the intended refactor issues; #63 is not part of this refactor
   batch.

Shelving should use `agent:paused` instead of relying on this manual restart
record.

## Current Phase 1 Resume Batch

Current label state after stopping the 21:27 PDT run:

- #735 `agent:todo` + `agent:paused`; draft PR #749 exists.
- #736 is closed with `agent:done`; PR #757 landed on `v2` at `3ea2f17`.
- #738 is closed with `agent:done`; PR #751 landed on `v2` at `88cc2de`.
- #739 `agent:rework` + `agent:paused`; PR #755 has request-changes review.
- #740 `agent:in-progress` + `agent:paused`; held for later sub-run.
- #741 `agent:in-progress` + `agent:paused`; held for later sub-run.
- #742 `agent:in-progress` + `agent:paused`; held for later sub-run.
- #743 `agent:in-progress` + `agent:paused`; held for later sub-run.
- #744 `agent:in-progress` + `agent:paused`; held for later sub-run.
- #748 `agent:in-progress` + `agent:paused`; interrupted by #768.

#737 T-003 is closed after PR #750 landed.

## Open PRs

| PR | Issue | State | Notes |
| --- | --- | --- | --- |
| #749 | #735 | Draft, checks green | RepoBase base-branch work; agent reported local implementation complete but git index/auth blocked handoff. |
| #755 | #739 | Open, checks green | Request-changes review posted: guard must be base-controlled and required on `v2`. Issue is `agent:rework` + `agent:paused`. |

## Shelved Phase 1 tickets

| Issue | Shelved label state | Runtime state before shelving | Restart note |
| --- | --- | --- | --- |
| #735 T-001 | `agent:todo` + `agent:paused` | Interrupted by #768 | Remove `agent:paused` only after Codex unavailable is cleared; PR #749 is still draft. |
| #739 T-005 | `agent:rework` + `agent:paused` | Review routed | Remove `agent:paused` after #768; agent should address the #755 request-changes review. |
| #740 T-006 | `agent:in-progress` + `agent:paused` | Held for later sub-run | Remove `agent:paused` only when ready to run the heavier characterization sub-run. |
| #741 T-007 | `agent:in-progress` + `agent:paused` | Held for later sub-run | Remove `agent:paused` only when ready to run the heavier characterization sub-run. |
| #742 T-008 | `agent:in-progress` + `agent:paused` | Held for later sub-run | Remove `agent:paused` only when ready to run the heavier characterization sub-run. |
| #743 T-009 | `agent:in-progress` + `agent:paused` | Held for later sub-run | Remove `agent:paused` only when ready to run the heavier characterization sub-run. |
| #744 T-010 | `agent:in-progress` + `agent:paused` | Held for later sub-run | Remove `agent:paused` only when ready to run the heavier characterization sub-run. |
| #748 T-006A | `agent:in-progress` + `agent:paused` | Interrupted by #768 | Remove `agent:paused` only after Codex unavailable is cleared. |

## Undispatched Phase 1 tickets

These are open and labeled for Phase 1, but intentionally have no active
`agent:*` state label:

- #745 T-011: Characterization: opencode slots, attach & FD budget
- #746 T-012: Characterization: renderer/app render-state & snapshots
- #747 T-013: Characterization: agent_runner drain/resume & digest

## Phase 0 fleet blockers

These issues are labeled `refactor phase:0`. They are unsnag-the-fleet bug
fixes, and their PRs target `main`.

| Issue | Purpose |
| --- | --- |
| #617 | Agent workspace GitHub DNS/API/auth failures. Landed on `main` via PR #763 (`937a264`). |
| #752 | Dashboard auth env leaks into agent test gates. Landed on `main` via PR #758 (`c06ecbb`). |
| #753 | Mix task startup fails when loopback PubSub gets `:eperm`. Landed on `main` via PR #761 (`fa8d799`). |
| #754 | Agent workspaces still block git index writes. Landed on `main` via PR #762 (`507dabb`). |
| #756 | Add `agent:paused` override label behavior so future shelving preserves old state automatically. Landed on `main` via PR #760 (`70c0e37`). |
| #764 | Explain and fix unexpected `agent:error` state swaps without retry-exhaustion logs. Landed on `main` via PR #767 (`c359333`). |
| #765 | Bound branch-poll remote calls so stuck SSH `git ls-remote` processes cannot linger. Landed on `main` via PR #766 (`3189103`). |
| #768 | Codex `{:error, :unavailable}` / usage-limit failures should pause agents instead of crashing or retry-looping. Open; no PR yet. |

## Latest Phase 1 run

Launched 2026-07-07 21:27 PDT from `v2` at `ad0d17f` with:

```bash
scripts/aiurdev build
scripts/aiurdev --bg --debug
```

Only #735 and #748 were unpaused enough to dispatch. #740-#744 were held with
`agent:paused`; #736 and #738 were restored to `agent:human-review`; #739 was
sent to `agent:rework` with `agent:paused` after the #755 request-changes
review.

The run was stopped after Codex app-server reported
`credits.hasCredits=false`, `AgentRunner` hit `{:error, :unavailable}`, and
both #735/#748 entered stall/retry churn. Phase 0 blocker #768 now tracks the
required fix or external-clear condition.

Post-stop merge work:

- PR #751 (#738) landed on `v2` at `88cc2de`; `make ci` from `src/` passed.
- PR #757 (#736) required one rework fix for order-dependent `:log_file`
  mutation in `IssueLogEventHistoryTest`, then landed on `v2` at `3ea2f17`.
  Fresh GitHub CI passed, the two-seed at-merge isolation probe printed
  `ISOLATED`, and post-merge `make ci` from `src/` passed.

## Latest Phase 0 run

Launched 2026-07-07 14:22 PDT with:

```bash
scripts/aiurdev --bg --debug
```

Before launch, the operator ran `scripts/aiurdev build`, switched
`tracker.base_branch` and workspace hooks to `main`, and applied `agent:todo`
only to #764 and #765. Both tickets moved to `agent:error` without local
retry-exhaustion evidence by 14:26 PDT, so the daemon was stopped and direct
backstop fixes took over. Both fixes landed on `main`; pull `main` into `v2`
before resuming the Phase 1 fleet.

## Previous Phase 0 run

Launched 2026-07-07 11:27 PDT with:

```bash
GITHUB_TOKEN= scripts/aiurdev --bg --debug
```

The empty `GITHUB_TOKEN` export is an operator workaround for #617: the token in
`.env` was rate-limited, while `gh` keyring auth still worked. Runtime
concurrency was set to five with `scripts/aiurdev set max-agents 5`, matching
the five Phase 0 blockers.

The run is now stopped. #617, #752, #753, #754, and #756 landed on `main`. #63
had an unrelated `agent:rework` label that leaked into the run; that active
label was removed so #63 stays out of Phase 0.

## Non-refactor note

#63 was active as unrelated rework and its active agent label was removed. Keep
it out of the refactor resume unless the operator explicitly wants to continue
that separate work.
