# merge_policy

The top-level policy is validated and displayed by `aiur status` and `aiur capabilities`; workers receive the current local-test mode on every turn (merge enforcement and main watching ship separately).

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `merge_policy.ci` | string | `wait` | `wait` (the only mode) requires full CI before merge. |
| `merge_policy.local_tests` | string | `partial` | `all`: full local suite; `partial`: tests relevant to the change, falling back to the full suite when selection is unsafe; `none`: compile and format only. |
| `merge_policy.full_ci_labels` | array | `[main-fix]` | Case-insensitive PR or ticket labels requiring full CI regardless of `ci`. |
| `merge_policy.full_ci_paths` | array | `[]` | Changed-path globs (`*`, `**`, `?`) requiring full CI regardless of `ci`; matches deleted paths too. |
| `merge_policy.premerge_checks` | array | `[]` | Commands to run on the merge result before merging. |
| `merge_policy.attribution_scan` | boolean | false | Enables the premerge AI-attribution scan of the PR title and body. |
| `merge_policy.main_watch.enabled` | boolean | false | Enables watching CI on the configured base branch. |
| `merge_policy.main_watch.workflows` | array | `[]` | Workflow names to watch; empty means every workflow on the base branch. |
| `merge_policy.main_watch.on_red` | string | `alert` | `alert` reports failed CI; `dispatch_fixer` requests a fixer ticket and priority dispatch. |
| `merge_policy.main_watch.fixer_label` | string | `main-fix` | Label for fixer tickets and their full-CI requirement. |
| `merge_policy.main_watch.canary_minutes` | integer | 45 | Minutes without a completed watched run before a canary rerun; `0` disables. |
| `merge_policy.main_watch.red_fallback_minutes` | integer | 0 | Optional full-CI wait after main stays red this many minutes; absent/`0` disables, `60` enables a one-hour threshold; enforcement ships in MP4. |

`on_red: dispatch_fixer` requires `fixer_label` in `full_ci_labels`. Lists reject blank entries; canary and red-fallback minutes must be nonnegative integers. Invalid values name the dotted config path.

Every PR must include a `## Local tests` section with `Policy`, `Tested head`
(the full 40-character pushed SHA), `Base` ref and SHA, `Selection`, and command
bullets such as ``- `mix test test/aiur/foo_test.exs` -> 42 tests, 0 failures``.
Update the section after every push.

For `partial`, cover changed tests, source mirrors, direct callers and deleted-name
references; use the full suite for shared test support, build/dependency/runtime
config or unknown file types. Use the target repository's test-selection tool
(Aiur's Elixir core uses `mix aiur.affected_tests`).

`mix pr_body.check --file <body.md>` validates the template and evidence shape.
CI reads the current PR body and head SHA and runs the same checker in
`workflow security`; stale `Tested head` values fail. Rerun that job after
correcting a rejected body.

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
