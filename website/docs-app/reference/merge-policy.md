# merge_policy

The operator merge command enforces this policy, status and capabilities display it, workers receive its local-test mode, and enabled main watching reports base-branch CI.

| Key | Type | Default | Controls | <!-- generated-reference:config-merge-policy-00 -->
| --- | --- | --- | --- |
| `merge_policy.attribution_scan` | boolean | false | Enables the premerge AI-attribution scan of the PR title and body. |
| `merge_policy.ci` | string | `wait` | `wait` (the only mode) requires full CI before merge. |
| `merge_policy.full_ci_labels` | array | `[main-fix]` | Case-insensitive PR or ticket labels requiring full CI regardless of `ci`. |
| `merge_policy.full_ci_paths` | array | `[]` | Changed-path globs (`*`, `**`, `?`) requiring full CI regardless of `ci`; matches deleted paths too. |
| `merge_policy.local_tests` | string | `partial` | `all`: full local suite; `partial`: tests relevant to the change, falling back to the full suite when selection is unsafe; `none`: compile and format only. |
| `merge_policy.main_watch.canary_minutes` | integer | 45 | Minutes without a completed watched run before rerunning the newest cancelled run; requires Actions write permission, otherwise raises attention. `0` disables. |
| `merge_policy.main_watch.enabled` | boolean | false | Watches completed CI on the configured base branch through webhooks and polling. |
| `merge_policy.main_watch.fixer_label` | string | `main-fix` | Label for fixer tickets and their full-CI requirement. |
| `merge_policy.main_watch.on_red` | string | `alert` | `alert` reports failed CI; `dispatch_fixer` files a P1 fixer after confirmed red CI and dispatches it first. |
| `merge_policy.main_watch.red_fallback_minutes` | integer | 0 | Optional full-CI wait after main stays red this many minutes; absent/`0` disables, `60` enables a one-hour threshold; the merge-policy consumer enforces the threshold using the watcher’s retained state. |
| `merge_policy.main_watch.workflows` | array | `[]` | Workflow names to watch; empty means every workflow on the base branch. |
| `merge_policy.premerge_checks` | array | `[]` | Commands to run on the merge result before merging. |

Premerge commands execute PR-authored code as the operator's Unix user. Token environment variables are removed, but that user can still read the stored `gh` credential. The default command list is empty; configure only checks for code you trust to execute.

`on_red: dispatch_fixer` requires `fixer_label` in `full_ci_labels`. Lists reject blank entries; canary and red-fallback minutes must be nonnegative integers. Invalid values name the dotted config path.

Fixer filing is opt-in: the default `on_red: alert` never files tickets. With
`on_red: dispatch_fixer`, a first-time failure alerts only. Red is confirmed when
the failed run fails again on a rerun attempt, or the next base commit fails the same job.

Confirmed red files a `priority:1`, `complexity:1` ticket with the fixer label.
The body includes run links, classified failures, red/last-green commits,
suspect merges and local reproduction commands. Known flakes alone file no fixer.

Repeated signatures and overlapping test failures update the existing ticket;
a separate ticket requires proven disjoint tests. A persisted creation receipt
per signature and red SHA prevents another ticket after the original is closed.

App-authored fixer tickets carrying the main-watch marker are authorized by this
config while `dispatch_fixer` remains enabled. Under PAT auth (or a shared daemon
and agent identity), tickets instead get `needs-triage` and an Executor attention.

Fixers take the next free slot first, within max-agents and the same CPU, memory,
explicit state limits and pause gates as other workers. After five minutes awaiting
first dispatch, `system.main.fixer.stalled` reports the observed hold reason or `unknown`.

Recovery comments on the open ticket without closing it; a missing open PR raises
attention. Fixer PRs require full CI.

Every PR must include a `## Local tests` section with `Policy`, `Tested head`
(the full 40-character pushed SHA), `Base` ref and SHA, `Selection`, and command
bullets such as ``- `mix test test/aiur/foo_test.exs` -> 42 tests, 0 failures``.
Update the section after every push.

For `partial`, cover changed tests, source mirrors, direct callers and deleted-name
references; use the full suite for shared test support, build/dependency/runtime
config or unknown file types. Use the target repository's test-selection tool
(Aiur's Elixir core uses `mix aiur.affected_tests`).

`mix pr_body.check --file <body.md>` validates the template and evidence shape.
CI runs the same checker in the `pr body` check, which reads the current PR
body and head SHA; stale `Tested head` values fail. Editing the body reruns
`pr body`, and `ci gate` requires its newest run, so a body fix needs no push.

An older `Tested head` still passes when it is an ancestor of the head and the
PR's contribution diff is identical, as for approval carry. A merge of the base
alone needs no body edit. The check logs which mode passed.

PRs opened at or before rollout are grandfathered out of the CI body gate.
The cutoff is the first-parent commit that adds `scripts/check-pr-body.py` to
the PR's base branch, so the feature commit date does not activate enforcement.
Before that landing, the CI body gate exempts existing PRs.

Optional `--policy all|partial|none` rejects evidence below that mode, and
`--head <SHA>` rejects stale evidence. Reviewers still compare test selection and
actual results with the diff; shape validation does not prove commands ran or
succeeded.

The AGENTS.md revert check for new tests applies in every local-test mode,
including `none`.

`aiur status` shows `main=unknown` or a color with the completed-run SHA and age, such as `main=green sha=abc123 age=180s`. Red includes its full UTC start date and any fixer ticket. Failed polls show `main=unavailable last_known=green sha=abc123 age=180s`; missing metadata stays `unknown`.

New failure signatures emit `system.main.ci.failed`; known-flake-only failures emit `system.main.ci.flaked`. A later green SHA emits `system.main.ci.failed.resolved`. State and failure history survive daemon restarts.

Actions read permission is required to attribute checks to workflows. Failed or denied reads retain the last known state and emit `system.main.ci.unavailable` once until the next successful observation.

Named workflows must run on every base push. For example, `[ci, "Publish Docker Image"]` works when both run on every push; a path-filtered workflow can leave status on an older SHA. Merge-queue commits without push runs are skipped. The first Actions page must reach back to the oldest commit in the 20-commit window.

Status reports `watcher=running|unavailable|not_running` for base CI and `landing_watcher=...` separately. The landing watcher follows approved heads through CI and queue, reruns failures with a non-PR cause, routes real failures to rework, and counts automatic merge-group requeues by hour. Starting base watching after boot requires a daemon restart.

PR reruns spend the per-head budget (two per head) and share the 3-per-15-minute cap with merge-group requeues; that cap survives restarts. Each rerun posts its reason on the PR. A PR waiting on the cap appears in `aiur executor-sweep` as `approved_pr_rerun_pending`.

A PR whose failure needs a fresh merge ref (stale merge ref, newer CI change, superseded job) is not rerun and appears as `approved_pr_refresh_pending`; a head that spent its budget or is backing off is not reclassified.

The landing watcher does not queue a PR whose ticket is in `agent:rework`, `agent:in-progress` or `agent:todo` (these win over a review label it still carries), so an Executor dequeue holds until the ticket returns to review.
