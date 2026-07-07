# Refactor Status

Last updated: 2026-07-07 11:29 PDT

## Current mode

The production-readiness refactor is paused while Phase 0 fleet blockers are
fixed. `scripts/aiurdev pause --all` was run, and Phase 1 active labels were
removed after this file captured the restart state.

The only current `agent:todo` issues should be the Phase 0 blockers listed
below. They are labeled `refactor phase:0` and target `main`. New agents
should treat these as fix-issues-first work, not normal refactor execution.

Phase 0 is not normal v2 refactor work. These are aiur reliability fixes that
unsnag the fleet itself, so their PRs should target `main`. After Phase 0 lands
on `main`, update `v2` from `main`, rebuild aiur, and then resume Phase 1.

The previous Phase 1 `agent:*` state is preserved in this document until #756
adds an `agent:paused` override label that can suppress work without losing the
previous state in GitHub labels.

## Resume notes

Before resuming Phase 1 refactor work:

1. Finish Phase 0 blocker fixes against `main`.
2. Pull the Phase 0 fixes from `main` into `v2`.
3. Run `scripts/aiurdev build` from the operator repo.
4. Restart or resume aiur with `scripts/aiurdev --bg --debug`.
5. Resume only the intended refactor issues; #63 is not part of this refactor
   batch and was paused only because the whole run was paused.
6. Continue PR review from the open PR list below.

Before running Phase 0 with aiur, make sure the active workflow targets `main`
instead of `v2`; otherwise the blocker fixes will open PRs against the refactor
integration branch instead of the production branch they need to unblock.

After #756 lands, shelving should use `agent:paused` instead of relying on this
manual restart record.

## Open PRs

| PR | Issue | State | Notes |
| --- | --- | --- | --- |
| #749 | #735 | Draft, checks green | RepoBase base-branch work; agent reported local implementation complete but git index/auth blocked handoff. |
| #750 | #737 | Open, checks green | SlotPolicy timeout hardening. Review started; merge-base diff is only the two timeout hunks. At-merge seed 0 opencode test passed in the #737 workspace; seed 1 still needs to run before merge. |
| #751 | #738 | Open, unstable | Website CI workflow. Agent paused after npm/GitHub DNS failures; PR test check is not green. |
| #755 | #739 | Draft, checks pending | Regression suite guard. Agent paused after local TCP denial/GitHub update failures. |

## Shelved Phase 1 tickets

| Issue | Shelved label state | Runtime state before shelving | Restart note |
| --- | --- | --- | --- |
| #735 T-001 | Was `agent:in-progress`; now no active `agent:*` label | Paused | PR #749 exists but is draft. Resolve #754/#617 class blockers before expecting autonomous commit/push. |
| #736 T-002 | Was `agent:in-progress`; now no active `agent:*` label | Paused | Scoped work applied locally; blocked by dashboard auth, Mix PubSub eperm, and out-of-scope `:log_file` contamination. |
| #737 T-003 | Was `agent:human-review`; now no active `agent:*` label | Deactivated | PR #750 is ready for operator review/merge checks; do not resume the agent unless rework is requested. |
| #738 T-004 | Was `agent:in-progress`; now no active `agent:*` label | Paused | PR #751 exists but is unstable due network-gate failure. |
| #739 T-005 | Was `agent:in-progress`; now no active `agent:*` label | Paused | PR #755 exists as draft; validation blocked by Mix loopback eperm. |
| #740 T-006 | Was `agent:in-progress`; now no active `agent:*` label | Paused | Agent reported local change/verification complete, but GitHub auth/DNS blocked publication. |
| #748 T-006A | Was `agent:in-progress`; now no active `agent:*` label | Paused | Agent completed validation locally; push/PR publication blocked by GitHub DNS. |

## Undispatched Phase 1 tickets

These are open and labeled for Phase 1, but intentionally have no active
`agent:*` state label:

- #741 T-007: Characterization: orchestrator lifecycle & dispatch gates
- #742 T-008: Characterization: GitHub ingestion & wake/rework
- #743 T-009: Characterization: engine identity, reap & control RPC
- #744 T-010: Characterization: workspace lifecycle & git metadata
- #745 T-011: Characterization: opencode slots, attach & FD budget
- #746 T-012: Characterization: renderer/app render-state & snapshots
- #747 T-013: Characterization: agent_runner drain/resume & digest

## Phase 0 fleet blockers

These issues are labeled `refactor phase:0` and should be fixed before normal
Phase 1 refactor work resumes. They are unsnag-the-fleet bug fixes, and their
PRs target `main`.

| Issue | Purpose |
| --- | --- |
| #617 | Agent workspace GitHub DNS/API/auth failures; updated with 2026-07-07 evidence. |
| #752 | Dashboard auth env leaks into agent test gates. |
| #753 | Mix task startup fails when loopback PubSub gets `:eperm`. |
| #754 | Agent workspaces still block git index writes. |
| #756 | Add `agent:paused` override label behavior so future shelving preserves old state automatically. |

## Current Phase 0 run

Launched 2026-07-07 11:27 PDT with:

```bash
GITHUB_TOKEN= scripts/aiurdev --bg --debug
```

The empty `GITHUB_TOKEN` export is an operator workaround for #617: the token in
`.env` was rate-limited, while `gh` keyring auth still worked. Runtime
concurrency was set to five with `scripts/aiurdev set max-agents 5`, matching
the five Phase 0 blockers.

The active Phase 0 tickets are #617, #752, #753, #754, and #756. #63 had an
unrelated `agent:rework` label that leaked into the run; that active label was
removed so #63 stays out of Phase 0.

## Non-refactor note

#63 was active as unrelated rework and is now paused because the whole run was
paused. Keep it out of the refactor resume unless the operator explicitly wants
to continue that separate work.
