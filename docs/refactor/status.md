# Refactor Status

Last updated: 2026-07-07 15:12 PDT

## Current mode

The production-readiness refactor is in Phase 0 blocker mode. The
2026-07-07 13:07 PDT Phase 1 run stopped itself after active tickets were
mass-moved to `agent:error` without retry-exhaustion logs. The 14:22 PDT
Phase 0 run reproduced the same unexpected state swap on #764 and #765. Direct
backstop fixes landed on `main` via PR #766 and PR #767.

Do not dispatch more Phase 1 refactor work until the new Phase 0 blockers are
handled and pulled back into `v2`.

Phase 0 is not normal `v2` refactor work. These are aiur reliability fixes that
unsnag the fleet itself, so their PRs target `main` first. After they land,
pull `main` back into `v2`, rebuild aiur, and only then resume normal Phase 1.

New Phase 0 tickets #764 and #765 are closed with `agent:done`. The local
dogfood `.aiur/config` and `.aiur/hooks` remain switched to `main`; switch them
back to `v2` after pulling these fixes into `v2`.

## Resume notes

Phase 1 restart checklist:

1. Pull the Phase 0 fixes from `main` into `v2`. Done: `520ad10`.
2. Run `scripts/aiurdev build` from the operator repo. Done.
3. Restart or resume aiur with `scripts/aiurdev --bg --debug`. Done for the
   13:07 PDT run, but that run is now error-stopped.
4. Resume only the intended refactor issues; #63 is not part of this refactor
   batch and was paused only because the whole run was paused.
5. Continue PR review from the open PR list below.

Before resuming Phase 1 again:

1. Fix or explicitly explain #764 (unexpected `agent:error` state swaps).
   Landed on `main` via PR #767 (`c359333`).
2. Fix or explicitly explain #765 (stuck SSH branch-poll subprocesses).
   Landed on `main` via PR #766 (`3189103`).
3. Pull `main` into `v2`.
4. Switch dogfood `.aiur/config` and `.aiur/hooks` back to `v2`.
5. Run `scripts/aiurdev build`, then launch with
   `scripts/aiurdev --bg --debug`.

Shelving should use `agent:paused` instead of relying on this manual restart
record.

## Current Phase 1 Resume Batch

The first post-Phase-0 run reactivated #735, #736, #738, #739, #740, #741,
#742, #743, #744, and #748. They are now stopped by `agent:error` labels, not
by completed work:

- #735 `agent:error`; draft PR #749 exists and local workspace has rebased work.
- #736 `agent:error` plus stale `agent:in-progress`; PR #757 needs rework.
- #738 `agent:error`; PR #751 needs rework.
- #739 `agent:error`; PR #755 needs owner decision or scoped follow-up.
- #740 `agent:error`; local characterization work was validating.
- #741 `agent:error`; local characterization work was validating.
- #742 `agent:error`; local characterization work was validating.
- #743 `agent:error`; local characterization work was validating.
- #744 `agent:error`; agent completed a local test-only diff, no PR.
- #748 `agent:error`; local warm-pool-capacity work was validating.

#737 T-003 is closed after PR #750 landed.

## Open PRs

| PR | Issue | State | Notes |
| --- | --- | --- | --- |
| #749 | #735 | Draft, checks green | RepoBase base-branch work; agent reported local implementation complete but git index/auth blocked handoff. |
| #751 | #738 | Open, checks green | Background review found two actionable issues: PR-only trigger misses direct-to-main deploy path, and CI uses npm while Netlify deploy uses Bun. Awaiting rework after #764/#765. |
| #755 | #739 | Open, checks green | Background review found broader enforcement concerns. The agent found they conflict with #739's exact scope; owner decision or follow-up scope needed before merge. |
| #757 | #736 | Open, checks green | Background review found an order-dependent `:log_file` restoration risk. Awaiting rework after #764/#765. |

## Shelved Phase 1 tickets

| Issue | Shelved label state | Runtime state before shelving | Restart note |
| --- | --- | --- | --- |
| #735 T-001 | Was `agent:in-progress`; now no active `agent:*` label | Paused | PR #749 exists but is draft. After #754/#617 landed, revalidate autonomous commit/push before resuming. |
| #736 T-002 | Was `agent:in-progress`; now no active `agent:*` label | Paused | Dashboard auth and Mix PubSub blockers landed; review out-of-scope `:log_file` contamination before resuming. |
| #737 T-003 | Was `agent:human-review`; now no active `agent:*` label | Deactivated | PR #750 is ready for operator review/merge checks; do not resume the agent unless rework is requested. |
| #738 T-004 | Was `agent:in-progress`; now no active `agent:*` label | Paused | PR #751 exists; review the website CI feedback before resuming the agent. |
| #739 T-005 | Was `agent:in-progress`; now no active `agent:*` label | Paused | PR #755 exists as draft with red CI; rerun validation after #753/#617 are integrated. |
| #740 T-006 | Was `agent:in-progress`; now no active `agent:*` label | Paused | Agent reported local completion; re-dispatch only after `v2` includes Phase 0 fixes. |
| #748 T-006A | Was `agent:in-progress`; now no active `agent:*` label | Paused | Agent completed validation locally; re-dispatch only after `v2` includes Phase 0 fixes. |

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
