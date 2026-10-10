# merge_policy

The top-level policy is validated and displayed by `aiur status` and `aiur capabilities`; enforcement, worker test instructions and main watching ship separately.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `merge_policy.ci` | string | `wait` | `wait` requires full CI; `pending_ok` permits pending checks with local-test evidence. |
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

Validation rejects `ci: pending_ok` unless `main_watch.enabled: true` and `local_tests` is `all` or `partial`. `on_red: dispatch_fixer` requires `fixer_label` in `full_ci_labels`. Lists reject blank entries; canary and red-fallback minutes must be nonnegative integers. Invalid values name the dotted config path.
