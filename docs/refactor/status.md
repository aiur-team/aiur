# Refactor Status

Last updated: 2026-07-07 13:18 PDT

## Current mode

The production-readiness refactor is restarting after Phase 0 fleet blockers
landed on `main` and were pulled into `v2`. The Phase 0 aiur daemon was stopped
after it began reclaiming unrelated #63 work from stale runtime state.

The first Phase 1 resume batch now has active labels. #63 is still out of scope.

Phase 0 is not normal v2 refactor work. These are aiur reliability fixes that
unsnag the fleet itself, so their PRs targeted `main`. `v2` now includes those
fixes at merge commit `520ad10`, and the operator checkout was rebuilt with the
same Phase 0 fixes cherry-picked.

The previous Phase 1 `agent:*` state is preserved in this document. #756 has
landed, so future shelving should use `agent:paused` instead of removing the
underlying lifecycle label manually.

## Resume notes

Phase 1 restart checklist:

1. Pull the Phase 0 fixes from `main` into `v2`. Done: `520ad10`.
2. Run `scripts/aiurdev build` from the operator repo. Done.
3. Restart or resume aiur with `scripts/aiurdev --bg --debug`.
4. Resume only the intended refactor issues; #63 is not part of this refactor
   batch and was paused only because the whole run was paused.
5. Continue PR review from the open PR list below.

Phase 0 is complete. If a future fleet-unblocking phase is needed, make sure the
active workflow targets `main` instead of `v2`; otherwise blocker fixes will open
PRs against the refactor integration branch instead of the production branch they
need to unblock.

Shelving should use `agent:paused` instead of relying on this manual restart
record.

## Current Phase 1 Resume Batch

These eight issues were reactivated for the first post-Phase-0 run:

- #735 T-001: `agent:todo`
- #739 T-005: `agent:rework`
- #740 T-006: `agent:todo`
- #748 T-006A: `agent:todo`
- #741 T-007: `agent:todo`
- #742 T-008: `agent:todo`
- #743 T-009: `agent:todo`
- #744 T-010: `agent:todo`
- #738 T-004: `agent:rework`
- #736 T-002: `agent:rework`

#736 T-002 deactivated back to human review during restart because PR #757 is
open, green, and mergeable, then returned to `agent:rework` after background
review found an order-dependent `:log_file` restoration risk. #737 T-003 is
closed after PR #750 landed. #738 T-004 returned to `agent:rework` after
background review found two workflow coverage issues in PR #751.

## Open PRs

| PR | Issue | State | Notes |
| --- | --- | --- | --- |
| #749 | #735 | Draft, checks green | RepoBase base-branch work; agent reported local implementation complete but git index/auth blocked handoff. |
| #751 | #738 | Open, checks green | Website CI workflow. Background review found two actionable issues: PR-only trigger misses direct-to-main deploy path, and CI uses npm while Netlify deploy uses Bun. Issue is back in `agent:rework`. |
| #755 | #739 | Draft, test failing | Regression suite guard. Agent paused after local TCP denial/GitHub update failures; CI test is red. |
| #757 | #736 | Open, checks green | Global log file test isolation. Background review found an order-dependent `:log_file` restoration risk; issue is back in `agent:rework`. |

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

These issues are labeled `refactor phase:0` and were fixed to unblock normal
Phase 1 refactor work. They are unsnag-the-fleet bug fixes, and their PRs
targeted `main`.

| Issue | Purpose |
| --- | --- |
| #617 | Agent workspace GitHub DNS/API/auth failures. Landed on `main` via PR #763 (`937a264`). |
| #752 | Dashboard auth env leaks into agent test gates. Landed on `main` via PR #758 (`c06ecbb`). |
| #753 | Mix task startup fails when loopback PubSub gets `:eperm`. Landed on `main` via PR #761 (`fa8d799`). |
| #754 | Agent workspaces still block git index writes. Landed on `main` via PR #762 (`507dabb`). |
| #756 | Add `agent:paused` override label behavior so future shelving preserves old state automatically. Landed on `main` via PR #760 (`70c0e37`). |

## Current Phase 0 run

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
