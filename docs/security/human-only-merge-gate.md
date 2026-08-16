# Merge gate

`human-only-merge-gate` protects both `main` and `develop`. It keeps three
properties, and nothing else:

1. **Branches can't be force-pushed or deleted** (`non_fast_forward`,
   `deletion`).
2. **A pull request needs one approval** (`pull_request`,
   `required_approving_review_count: 1`). This is what stops Aiur agents from
   self-merging: an agent-authored PR still needs an approval it cannot give
   itself.
3. **Every blocking CI check must pass** (`required_status_checks`). This is the
   "green main" guarantee.

The Executor (`its-everdred`) is a bypass actor scoped to the pull-request rule
(`bypass_mode: pull_request`), so it can merge on its own judgment without the
approval dance — but the required-status-checks rule still applies, so it cannot
merge a red build.

The old gate's CODEOWNER review, last-push approval, and merge queue were
removed. They solved the same "human must approve" problem with far more
machinery (a squash-only merge queue that broke `develop → main` re-merges, and
a two-identity CODEOWNERS dance). One approval plus an Executor bypass is the
simpler equivalent.

The reviewed API declaration is
[`human-only-merge-ruleset.json`](human-only-merge-ruleset.json). An operator
with repository-administration permission applies or updates it with:

```sh
scripts/apply-human-only-merge-ruleset.sh
```

## Verification

`scripts/verify-human-only-merge-ruleset.sh` lets an administrator verify the
live ruleset on demand. It is deliberately not run in CI because GitHub hides
`bypass_actors` from read-only tokens, and placing an Administration credential
in Actions would expand the CI trust boundary. It asserts the exact
`bypass_actors` entry (`its-everdred`, `pull_request`) alongside the pull-request
and status-check rules.

A read-only drift check (`scripts/verify-human-only-merge-ruleset-live.sh`) runs
in CI on every pull request and merge as the `merge ruleset drift` check. It
verifies every property a read-only token can see — active protection of `main`
and `develop`, a pull-request rule with one approval and stale-review dismissal,
and the `required_status_checks` rule matching the declaration exactly. It does
not assert `bypass_actors`, which GitHub hides from read-only tokens; that stays
in the admin verifier's domain.

Both verifiers are fixture-tested by
`scripts/test-human-only-merge-ruleset.sh` (admin) and
`scripts/test-human-only-merge-ruleset-live.sh` (read-only), which run as part
of the `workflow security` CI job.
