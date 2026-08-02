# Human-only merge gate

`human-only-merge-gate` protects both `main` and `develop`. It requires a
pull request, an approval from a CODEOWNER, and an approval by someone other
than the most recent pusher. Pushing a reviewable commit dismisses existing
approvals. It also requires every blocking CI check to pass, with strict status
checks enabled so the pull request must be up to date with its target branch.
The ruleset has no bypass actors.

The reviewed API declaration is
[`human-only-merge-ruleset.json`](human-only-merge-ruleset.json). An operator
with GitHub repository-administration permission applies or updates it with:

```sh
scripts/apply-human-only-merge-ruleset.sh
```

The declaration requires every blocking CI job to succeed, with GitHub Actions
fixed as the expected check source. The required `workflow security` check is
the CI job that runs the ruleset verifier itself; `build` and `test` are also
explicitly required alongside the remaining blocking jobs. Strict status
checks mean the exact proposed head must be tested after the branch is brought
up to date with its target branch.

`scripts/verify-human-only-merge-ruleset.sh` lets an administrator verify the
live GitHub ruleset on demand. It is deliberately not run in CI: GitHub hides
`bypass_actors` unless the caller has ruleset write visibility, and placing
that Administration credential in Actions would expand the CI trust boundary.

The verifier requires both `conditions.ref_name.exclude` and `bypass_actors`
to be present and exactly `[]`. Missing or `null` properties fail the audit:
an omitted `bypass_actors` property means the credential cannot prove that
the live ruleset has no bypass.

Aiur's landing automation follows this same gate: it waits for the required
GitHub status checks and review conditions before issuing a squash merge. It
does not use auto-merge or a bypass actor, and it cannot merge a stale, pending,
or failing head. GitHub remains authoritative about whether a merge occurred.
The daemon's merge attribution is defense in depth, not permission to bypass
this gate.
`tracker.github.human_mergers` is a distinct, explicit allowlist for human
mergers. It does not inherit CODEOWNERS, `bot_account`, `trusted_accounts`, or
the dispatch `allowed_users`; absent configuration denies every merger and
raises a critical needs-attention alert. This repository permits only
`its-everdred`.

The declaration is the required steady state. The solo-operator release-merge
deadlock and any auditable, time-bounded maintenance procedure are tracked in
#1437 rather than encoded as a CI exception here.
