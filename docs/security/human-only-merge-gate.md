# Human-only merge gate

`human-only-merge-gate` protects both `main` and `develop`. It requires a
pull request, an approval from a CODEOWNER, and an approval by someone other
than the most recent pusher. Pushing a reviewable commit dismisses existing
approvals. The ruleset has no bypass actors.

The reviewed API declaration is
[`human-only-merge-ruleset.json`](human-only-merge-ruleset.json). An operator
with GitHub repository-administration permission applies or updates it with:

```sh
scripts/apply-human-only-merge-ruleset.sh
```

The declaration also requires every blocking CI job to succeed, with GitHub
Actions fixed as the expected check source. Branches do not need to be rebased
onto the latest target-branch commit before merging, but the exact proposed
head commit must have successful checks.

`scripts/verify-human-only-merge-ruleset.sh` lets an administrator verify the
live GitHub ruleset on demand. It is deliberately not run in CI: GitHub hides
`bypass_actors` unless the caller has ruleset write visibility, and placing
that Administration credential in Actions would expand the CI trust boundary.

The verifier requires both `conditions.ref_name.exclude` and `bypass_actors`
to be present and exactly `[]`. Missing or `null` properties fail the audit:
an omitted `bypass_actors` property means the credential cannot prove that
the live ruleset has no bypass.

A read-only drift check (`scripts/verify-human-only-merge-ruleset-live.sh`)
runs in CI on every pull request and merge as the `merge ruleset drift` check.
It verifies every property a read-only token can see — that the ruleset
actively protects `main` and `develop`, that the `pull_request` rule requires
current CODEOWNER approval and dismisses stale reviews, and that the
`required_status_checks` rule carries exactly the declared GitHub Actions
contexts — so a regressed gate fails CI visibly instead of silently. It does
not assert `bypass_actors` (hidden from read-only tokens) or
`strict_required_status_checks_policy` (reconciled by #1487 and enforced by
the admin verifier); both stay in the admin verifier's domain. The drift check is
not yet a required status check: promoting it requires adding its context to
the reviewed declaration and applying the updated ruleset.

The daemon's merge attribution is defense in depth, not permission to bypass
this gate: GitHub remains authoritative about whether a merge occurred. The
application has no merge path to guard — the daemon and CLI never issue a
merge, they only observe and attribute `pr_merged` events — so the CI drift
check is the automated enforcement mechanism, not an application-side guard.
`tracker.github.human_mergers` is a distinct, explicit allowlist for human
mergers. It does not inherit CODEOWNERS, `bot_account`, `trusted_accounts`, or
the dispatch `allowed_users`; absent configuration denies every merger and
raises a critical needs-attention alert. This repository permits only
`its-everdred`.

The declaration is the required steady state. The solo-operator release-merge
deadlock and any auditable, time-bounded maintenance procedure are tracked in
#1437 rather than encoded as a CI exception here.
