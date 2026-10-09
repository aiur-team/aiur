---
title: Merge policy as aiur config - Plan
type: feat
date: 2026-10-09
topic: merge-policy
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
base_main_sha: fd158cef8
---

# Merge policy as aiur config - Plan

## Goal Capsule

- **Objective:** move the aiur repo's "merge before CI finishes" rule out of
  Executor memory and shell scripts into a `merge_policy` config section that
  aiur code enforces. The Executor cannot forget a rule that the merge command,
  the worker prompt and the daemon read from config.
- **Product authority:** Kevin, 2026-10-08 ("this is always true for aiur
  repo"): "do not wait on CI for every PR. Have agents run all the relevant
  tests to their code locally, then open the PR... if the PR is ready to merge
  and we're still waiting on CI... merge and for you to just keep an eye on
  main. If you ever see that it fails red, I want you to spin up an additional
  background worker to quickly fix main. Await full CI only on those PRs."
  Kevin, 2026-10-09, on the Executor's proposal: "require_local_tests should
  have option: all, partial, none. which should tell the agent. partial is
  only relevant to the change".
- **Open blockers:** none for planning. Operator questions are at the end, each
  with a recommendation that the plans assume.

## Summary

Add a top-level `merge_policy` config section. One CLI command, `aiur pr
merge <N>`, replaces `merge-if-safe.sh` and enforces the policy with the
operator's own credential. The worker prompt states the `local_tests` mode, and
every PR body carries the commands the agent ran and their results. A daemon
main-watch replaces `main-watch.sh`. It emits `system.main.ci.failed` with the
failing tests, and it can file and dispatch a P1 `main-fix` ticket. `aiur
status` and `aiur capabilities` print the active policy. The aiur repo sets
`ci: pending_ok` and `local_tests: partial`. Other repos default to `ci: wait`
and `local_tests: partial`.

## Problem Frame

The rule exists only in Executor text and scripts:

- `~/.aiur/review-scratch/REVIEWER-BRIEF.md` rules 5a, 5b, 5f, 5g and 6.
- `~/.aiur/review-scratch/merge-if-safe.sh`: fetch the PR head, refuse on a
  merge-tree conflict, run `check-components.py` and `check-file-size.py` on
  the merge result, refuse when the head moved, when the PR is a draft, when a
  check FAILED (minus an operator-named `INHERITED_FAILS` list), or when the
  title or body carries AI attribution; then approve and `gh pr merge --squash
  --admin` as `its-everdred`, and append to `early-merges.log` (190 merges so
  far).
- `~/.aiur/review-scratch/main-watch.sh`: every 120 s, list `ci` runs on
  `main` push; print `MAIN RED` once per failed run; rerun the newest
  cancelled run as a canary when no run completed for 45 min (#3212 lets main
  runs supersede each other).
- The Executor's memory note and handoff.

Each piece is lost when a new Executor boots without the scratch directory.
Worse, the committed guidance says the opposite: `.claude/skills/aiur-run/SKILL.md`
(about line 1228) and `references/executor.md` (about line 486) say "never
merge a pending, failing, or stale head". A fresh Executor that reads the skill
follows the skill.

Verified facts that shape the design (origin/main `fd158cef8`):

- **Config.** No merge setting exists except `tracker.github.human_mergers`,
  which only drives post-merge attribution alerts
  (`src/lib/aiur/orchestrator/comment_wake.ex`) and the PR-health scanner. The
  docs disagree on its meaning (`.aiur/examples/config.example` vs
  `website/docs-app/reference/configuration.md`).
- **The daemon never merges** (`src/lib/aiur/orchestrator/ci_lifecycle.ex`
  cites the human-only merge gate, #1841). For an approved PR it emits
  `ticket.<id>.pr.parked_ready` and tells the Executor to run `gh pr merge
  --auto`.
- **Identity.** CLI commands run over RPC inside the daemon, so they act as the
  daemon identity (App bot or `bot_account`). There is no operator credential
  in code. The ruleset bypass actor is `its-everdred` with `bypass_mode:
  pull_request` (`docs/security/human-only-merge-ruleset.json`). That bypass
  is what lets `--admin` merge with required checks pending.
  `docs/security/human-only-merge-gate.md` claims the bypass "cannot merge a
  red build". That is wrong: the bypass skips the status-check rule too, so a
  failed check is blocked only by the client-side script today.
- **Main CI.** The webhook normalizer drops every check delivery with no PR
  (`src/lib/aiur/events/github_webhook/normalizer.ex`, `check_reconcile/2`),
  so a main push run is always dropped. `workflow_run` is not subscribed. The
  CI poller polls PR heads only. Nothing in `src/lib` watches main.
- **Permissions.** The GitHub App has Actions = Never
  (`website/docs-app/apis/github.md`). The daemon cannot read job logs or
  rerun jobs. It can read check runs and their annotations.
- **Flakes.** `.github/known-flaky-tests.txt` lists known ExUnit flakes, and
  `scripts/report-known-flaky-tests.sh` classifies a failed partition's tests
  into the job's step summary. The daemon cannot read step summaries. The only
  daemon-side flake rule is a one-cycle deferral when the check named `test`
  fails alone.
- **Issues.** The daemon has no issue-creation code. A ticket the daemon labels
  is dispatchable only when an allowed user triaged it earlier
  (`src/lib/aiur/github/dispatch_authorization.ex`, `prior_triage`). A
  daemon-filed ticket therefore never dispatches today.
- **Test selection.** `Aiur.AffectedTests` and `mix aiur.affected_tests`
  already map changed paths to test files and force a full run when the change
  cannot be classified. `.claude/skills/aiur-agent/dev-loop.md` already tells
  agents to run affected tests only.
- **PR body.** `.github/pull_request_template.md` has a Test Plan checkbox, no
  results. `mix pr_body.check` enforces template headings but CI does not run
  it.

## Approaches

**A. Config plus one enforcing command (chosen).** The policy lives in config.
Three consumers read it: `aiur pr merge` (the only merge path the Executor
uses), the worker prompt, and the daemon main-watch. The command is the
guarantee: it refuses what the policy forbids, whoever runs it.

**B. Daemon auto-merge.** The daemon merges approved PRs itself under the
policy. It removes the Executor step, but it gives a daemon credential the
merge bypass, which #1841 and the human-only merge gate exist to prevent. It
also needs the operator's credential inside the daemon. Rejected for this
epic; listed as an open question.

**C. Config only, scripts stay.** Put the values in config and keep the shell
scripts reading them with `yq`. Cheapest, but the scripts stay outside the
repo, untested, and per-machine. It does not meet "cannot forget".

**D. Inversion: make CI fast enough to wait.** #3096 (CI capacity) is the
real root cause, and it stays open. A 16-minute, capacity-limited CI run will
not become a 2-minute one within this epic, so the policy is still needed.

## Product Contract

### Requirements

- R1. A top-level `merge_policy` section exists with `ci` (`wait` |
  `pending_ok`), `local_tests` (`all` | `partial` | `none`),
  `full_ci_labels`, `full_ci_paths`, `premerge_checks`, `attribution_scan`
  and a `main_watch` sub-section (`enabled`, `workflows`, `on_red` = `alert` |
  `dispatch_fixer`, `fixer_label`, `canary_minutes`). Defaults: `ci: wait`,
  `local_tests: partial`, `full_ci_labels: [main-fix]`, `main_watch.enabled:
  false`, `on_red: alert`.
- R2. A FAILED check always blocks a merge. No config value changes that.
- R3. `ci: pending_ok` without `main_watch.enabled: true` is a config error.
  `ci: pending_ok` with `local_tests: none` is a config error. Merging early
  is safe only with local evidence before and a watcher after.
- R4. `aiur pr merge <N> --reviewed-sha <sha>` merges a PR only when every
  check passes: approval or bypass identity, not a draft, head equals the
  reviewed SHA, no merge-tree conflict with the base, `premerge_checks` pass on
  the merge result, no FAILED check except a verified inherited failure, the
  attribution scan passes (when enabled), and the CI state the policy needs.
- R5. The CI state needed: under `wait`, every required check passed. Under
  `pending_ok`, required checks passed or pending, and the PR body carries
  local-test evidence for the current head. A PR with a `full_ci_labels`
  label (on the PR or its ticket) or a file matching `full_ci_paths` always
  needs `wait`.
- R6. `aiur pr merge` acts as the operator's own credential, never the daemon
  or agent token. It refuses when the acting login is the `bot_account`, the
  App account, or not in `human_mergers`, or when it runs inside an agent
  workspace.
- R7. Every merge prints and records its outcome: PR, SHA, pending checks at
  merge, policy applied. The daemon receives a `system.pr.merged` event so
  main-watch can name early merges when main turns red.
- R8. The worker prompt states the `local_tests` mode in words. `all` runs
  the repo's full local test suite. `partial` runs the tests relevant to the
  change (defined in R9). `none` runs compile and format checks only and
  relies on CI.
- R9. "Relevant to the change" means: test files the diff changes, the mirror
  test of each changed source file, tests of direct dependents (callers) of
  changed modules, and tests that still reference a name the diff deletes. If
  the selection cannot be made safely (shared test support, build files,
  config, unknown file types), the agent runs the full suite. The aiur repo
  uses `mix aiur.affected_tests`, which already implements this.
- R10. Every PR body has a `Local tests` section: the policy mode, the head SHA
  tested, each command, its result line, and for `partial` one line on how the
  set was chosen. Reviewers check the evidence covers the change.
- R11. When a watched workflow run on the base branch fails, the daemon emits
  `system.main.ci.failed` once per failure signature with: SHA, run URL,
  failing checks, failing tests, each test's known-flake status, and the PRs
  merged since the last green run (early merges marked). Recovery emits
  `system.main.ci.failed.resolved`.
- R12. With `on_red: dispatch_fixer`, a failure that is not only known flakes
  files one P1 ticket labelled with `fixer_label` and dispatches it ahead of
  other work. An open ticket with the same signature gets a comment, not a
  second ticket. A known-flake-only failure files nothing and is reported as a
  flake.
- R13. Fixer PRs wait for full CI (the `fixer_label` is in `full_ci_labels`;
  config validation enforces it).
- R14. `aiur status` prints one merge-policy line, including main's state.
  `aiur capabilities` reports a `merge_policy` capability with the mode.
- R15. The aiur repo's `.aiur/config` sets `ci: pending_ok`, `local_tests:
  partial`, `attribution_scan: true`, its two premerge checks,
  `main_watch.enabled: true`, `workflows: [ci]`, `on_red: dispatch_fixer`.
- R16. The aiur-run skill and Executor reference follow `merge_policy` instead
  of the absolute "never merge a pending head" rule, and name `aiur pr merge`
  as the only merge path. The scratch scripts are retired.

### Key Decisions

- **Top-level `merge_policy`, not under `tracker.github`.** Merging and main
  CI are about the code host and CI, not the ticket tracker. A Linear-tracked
  repo still merges on GitHub.
- **The merge command runs standalone, not over daemon RPC.** It resolves the
  operator's credential with `gh auth token` with `GITHUB_TOKEN` and `GH_TOKEN`
  removed, so the token never enters the daemon and the daemon's identity can
  never merge. This keeps the #1841 boundary. It still sends a best-effort
  `system.pr.merged` event to a running daemon.
- **`human_mergers` becomes the merge allowlist too.** It already names the
  only human merge identity. The docs drift is fixed in the same ticket.
- **Inherited failures are verified, not asserted.** `--inherited <check>` is
  accepted only when main-watch recorded that check failing on a main SHA at or
  before the PR's merge base and passing on a later main SHA. Before main-watch
  ships, the flag refuses. This replaces the operator-typed `INHERITED_FAILS`.
- **Evidence is enforced at merge time for early merges only.** Under
  `pending_ok`, a PR without a `Local tests` section for its current head does
  not merge early; it waits for CI. Under `wait`, missing evidence is a
  reviewer finding, not a merge block.
- **Failing tests reach the daemon through check-run annotations.** CI's
  known-flaky reporter also writes one annotation per failing test with its
  classification. The daemon reads annotations with Checks: read, which it
  already has. This avoids granting Actions: read just to read logs.
- **The failure digest is shared with #3864.** #3864 (stuck ci-wait PRs) must
  also tell a flake from a real failure. One module classifies failures for
  both, built first (MP0). #3864 is linked as blocked by it.
- **Known flakes = `.github/known-flaky-tests.txt` plus open issues labelled
  `flake`.** The file is the classifier CI already uses. The label lets an
  issue that is not yet in the file count, and gives dedupe a target. The
  existing flake tickets (#3861, #3852, #3854, #3851, #3775, #3776, #3773,
  #3611, #3569, #3558, #2402, #2655) get the label.
- **Daemon-filed fixer tickets are authorized by config.** The operator's
  `on_red: dispatch_fixer` is the authorization. Dispatch authorization accepts
  a ticket the daemon account created, carrying the main-watch marker and the
  fixer label, only while `on_red: dispatch_fixer`. Under PAT auth the daemon
  and agents share one login, so the marker could be forged; there the ticket
  is filed with `needs-triage` and an alert instead.
- **"At once" means front of queue plus one reserved slot.** A fixer ticket
  sorts before all other dispatch candidates and may use one slot above the
  agent cap. It still obeys the host load gate.
- **Reruns are capability-gated.** Main-watch's canary rerun and flake rerun
  need Actions: write. When the App lacks it, main-watch raises attention for
  the Executor to rerun instead. Granting it is an open question.
- **Not frozen while main is red.** Early merges continue while main is red;
  `aiur pr merge` prints main's state and the open fixer ticket. Freezing the
  fleet on every red costs more than the rare compound break.

### Key Flows

- F1. **Early merge.** Agent runs `partial` tests, writes evidence, opens a
  ready PR. Reviewer approves. Executor runs `aiur pr merge 4012
  --reviewed-sha abc123`. The command sees 6 pending, 0 failed checks,
  evidence for `abc123`, no full-CI label, and merges with the bypass.
- F2. **Main red.** A `ci` run on main fails. Main-watch reads the failing
  check runs and their annotations, classifies 1 new failure, lists the 3 PRs
  merged since the last green run (2 early), emits `system.main.ci.failed`,
  files "Main red: <test> at <sha>" with `main-fix`, `priority:1`,
  `agent:todo`, and dispatches it. The fixer PR waits for full CI.
- F3. **Flake on main.** All failures are known flakes. Main-watch emits
  `system.main.ci.flaked`, comments the run on each flake ticket, and reruns
  the run (or asks the Executor to). No fixer ticket.
- F4. **Recovery.** A later main run passes all watched checks. Main-watch
  emits `.resolved` and comments on the open fixer ticket. It does not close
  a ticket an agent is working.

### Acceptance Examples

- AE1. `ci: wait`, one check pending: `aiur pr merge` refuses with "waiting
  for CI (policy ci=wait)" and exits 2.
- AE2. `ci: pending_ok`, one check FAILED, no main record: refuses "CI
  failed: coverage (2/4)".
- AE3. `ci: pending_ok`, PR labelled `main-fix`, checks pending: refuses
  "full CI required (label main-fix)".
- AE4. Run from an agent workspace, or `gh` resolves to `its-applekid`:
  refuses "merge identity must be in human_mergers".
- AE5. Two main runs fail with the same failing test: one fixer ticket, one
  comment on it.
- AE6. A fresh Executor with no scratch directory runs `aiur status` and sees
  `MERGE POLICY ci=pending_ok local_tests=partial main=red #4100`.

### Scope Boundaries

- No daemon auto-merge (open question).
- No change to the GitHub ruleset itself; only its doc is corrected.
- No CI speed work; #3096 owns it.
- #3835 (the `website` workflow is red on every main push) is not fixed here;
  `main_watch.workflows: [ci]` keeps it out of the signal.
- Stuck ci-wait PR reruns stay in #3864.

### Dependencies / Assumptions

- The operator's `gh` login on the machine that runs `aiur pr merge` is the
  ruleset bypass actor. `aiur pr merge` reports GitHub's refusal clearly when
  it is not.
- Agents run as the same Unix user and could call `gh` without the guard. The
  workspace check in R6 is a guard, not a security boundary; the boundary
  stays the ruleset approval and bypass list.
- The GitHub App keeps Checks: read and Issues: write.

### Open questions for Kevin

1. **Grant the App Actions: read and write?** Needed for canary and flake
   reruns (here and in #3864) and for job logs. **Recommend yes**, Actions
   only; until then main-watch asks the Executor to rerun.
2. **Should the daemon merge by itself later (approach B)?** **Recommend no**
   for now. Revisit after `aiur pr merge` has run a week with no wrong merge.
3. **`full_ci_paths` for the aiur repo?** **Recommend**
   `.github/workflows/**`, `src/mix.exs`, `src/mix.lock`: a CI or dependency
   change merged early can break every later PR's CI at once.
4. **Freeze early merges while main is red?** **Recommend no freeze**, but fall
   back to `wait` automatically when main has been red for more than 60 min
   (a fixer that is not landing means something is wrong). Plans implement no
   freeze and keep the 60-minute fallback as an option off by default.
5. **Should `local_tests: all` be the default for other repos?** **Recommend
   `partial`** (as proposed): it matches what agents already do and keeps
   turns short.

## Sources / Research

- `~/.aiur/review-scratch/merge-if-safe.sh`, `main-watch.sh`,
  `REVIEWER-BRIEF.md` (operator machine, not in repo).
- `src/lib/aiur/config/schema.ex`, `schema/tracker.ex`, `github/config.ex`.
- `src/lib/aiur/events/github_webhook/normalizer.ex`,
  `events/github_ci_poller.ex`, `orchestrator/ci_lifecycle.ex`,
  `github/dispatch_authorization.ex`, `executor_bindings.ex`.
- `src/lib/aiur/prompt_builder.ex`, `src/prompts/shared-agent-instructions.md`,
  `src/lib/aiur/affected_tests.ex`, `.claude/skills/aiur-agent/dev-loop.md`.
- `.claude/skills/aiur-run/SKILL.md`, `references/executor.md`.
- `docs/security/human-only-merge-gate.md`, `human-only-merge-ruleset.json`.
- `website/docs-app/apis/github.md`, `reference/configuration.md`,
  `scripts/check-config-docs.py`.
- `.github/known-flaky-tests.txt`, `scripts/report-known-flaky-tests.sh`.
- Related tickets: #3864, #3096, #3835, #3212, flake tickets listed above.

## Ticket split

| Ticket | Plan | Blocked by | Complexity |
|---|---|---|---|
| MP0 CI failure digest | [plan-mp0-failure-digest.md](plan-mp0-failure-digest.md) | none | 2 |
| MP1 Config and visibility | [plan-mp1-config.md](plan-mp1-config.md) | none | 2 |
| MP2 `aiur pr merge` | [plan-mp2-pr-merge.md](plan-mp2-pr-merge.md) | MP1, MP3 | 3 |
| MP3 Local-tests mode and PR evidence | [plan-mp3-local-tests.md](plan-mp3-local-tests.md) | MP1 | 2 |
| MP4 Daemon main-watch | [plan-mp4-main-watch.md](plan-mp4-main-watch.md) | MP0, MP1 | 3 |
| MP5 Fixer ticket filing and dispatch | [plan-mp5-fixer-dispatch.md](plan-mp5-fixer-dispatch.md) | MP4 | 2 |
| MP6 Executor adoption | [plan-mp6-executor-adoption.md](plan-mp6-executor-adoption.md) | MP2, MP3, MP5 | 1 |

#3864 is blocked by MP0 (shared failure classification).
