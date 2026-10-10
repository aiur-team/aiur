# Merge gate

Two repository rulesets gate merges. Both are declared in this directory and
compared with GitHub by CI.

## `human-only-merge-gate`

Protects `main` and `develop`. Declaration:
[`human-only-merge-ruleset.json`](human-only-merge-ruleset.json).

1. **Branches can't be force-pushed or deleted** (`non_fast_forward`,
   `deletion`).
2. **Every blocking CI check must pass** (`required_status_checks`). This is the
   "green main" guarantee.

The ruleset no longer requires an approving review. The `pull_request` rule
(one approval, stale reviews dismissed on push) was removed by operator decision
on 2026-10-10, so GitHub itself does not stop a pull request from merging
unapproved; the name is historical. Whether a pull request is reviewed before it
merges is now Aiur's workflow (`agent:human-review`), not a GitHub rule.

The declaration still lists `its-everdred` as a bypass actor
(`bypass_mode: pull_request`). GitHub hides `bypass_actors` from read-only
tokens, so only the admin verifier below can confirm the live value.

## `main` (merge queue)

Protects `main`. Declaration:
[`main-merge-queue-ruleset.json`](main-merge-queue-ruleset.json). Enabled on
2026-10-10 after being disabled since 2026-07-30.

- `deletion` and `non_fast_forward`, as above.
- `merge_queue`: squash merges, `HEADGREEN` grouping, a batch of at least 4
  entries or a 15-minute wait, at most 5 entries per merge and 2 building at
  once, and a 120-minute check response timeout.

The declaration omits `bypass_actors`, which a read-only token cannot read, so
applying it leaves the live bypass list as it is.

## Applying

An operator with repository-administration permission applies or updates both
declarations with:

```sh
scripts/apply-human-only-merge-ruleset.sh
```

Pass declaration paths to apply only some of them. Change the declaration and
the live ruleset together: a ruleset edited only in the GitHub UI fails the
`merge ruleset drift` check on every pull request until the declaration
matches.

## Verification

`scripts/verify-human-only-merge-ruleset.sh` lets an administrator verify the
live `human-only-merge-gate` ruleset on demand. It is deliberately not run in CI
because GitHub hides `bypass_actors` from read-only tokens, and placing an
Administration credential in Actions would expand the CI trust boundary. It
asserts the exact `bypass_actors` entry (`its-everdred`, `pull_request`)
alongside the status-check rule. It does not cover the `main` ruleset.

A read-only drift check (`scripts/verify-human-only-merge-ruleset-live.sh`) runs
in CI on every pull request and merge as the `merge ruleset drift` check. It
verifies every property a read-only token can see. For `human-only-merge-gate`:
active protection of `main`, the `required_status_checks` rule matching the
declaration exactly, and the same set of rule types as the declaration, so a
rule added or removed in the UI is drift. For `main`: target, enforcement,
branch conditions and every rule parameter equal to the declaration. It does not
assert `bypass_actors`.

Both verifiers are fixture-tested by
`scripts/test-human-only-merge-ruleset.sh` (admin) and
`scripts/test-human-only-merge-ruleset-live.sh` (read-only), which run as part
of the `workflow security` CI job.
