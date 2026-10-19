# CI failure evidence

GitHub App installs need `Checks: Read`. Failed ExUnit shards emit `aiur-test-failure` annotations with classification, exact test identity and repository-relative source path/line when ExUnit reports them. Annotations are capped at nine tests plus a truncation notice.

`Aiur.CI.FailureDigest.build(sha)` returns checks/URLs, tests/paths, signature and `truncated`/`flake_only`/`test_only` flags. Complete test evidence can justify an unrelated-test rerun; missing paths cannot prove a test is outside the PR diff.

Known flakes match the SHA-specific file or an open `flake` issue (whole line or Markdown code); `aiur init` provisions the label. Unknown reads, truncation and independent check errors are never flake-only. `aiur-derived-failure` names upstream checks: rollups are flake-only only when every named check is proven flake-only.

Signatures exclude proven flakes. ResourceStore caches completed evidence by SHA/check identities; reruns refresh and failed reads retry. Open flake issues are shared for 60 seconds. Reads use caller `ci_failure_digest`, never Actions logs; no quota saving is claimed.

Failed-job recovery requires Actions read/write. It is bounded to one rerun per head and three failed handoffs per PR, without a fleet or hourly cap. A run GET returning 403/404 or a denied rerun POST raises one attention and permits normal rework.

Any other recovery stop also raises its attention and routes a red head to rework. Some cases hold the head instead: a rerun in flight; an approved head whose landing state is unreadable; and a transient GitHub error, which holds for ten minutes and is then retried once before the head routes. An Actions 403 or 404 routes at once. A hold recorded before the head went red, for example for a cancelled run, does not mask a later failure.

With `merge_policy.main_watch.enabled`, a red head routes only when the PR caused it. That means a failing check passed on the PR's base commit in MainWatch history, or never ran there. A check that is also red on the base, or a base commit MainWatch has not recorded, holds the head with one `base_inherited` or `base_unknown` attention. The gate re-checks on every poll.

The [cancelled-run policy](https://github.com/aiur-team/aiur/pull/4212) handles a separate trigger. A head can receive two reruns from distinct triggers: a failed-job rerun here and a cancelled-run rerun there.
