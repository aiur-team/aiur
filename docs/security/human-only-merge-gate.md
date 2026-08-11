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

## Stale-base refresh procedure

`require_last_push_approval` applies to the last reviewable push. A base refresh
that brings new changes into the pull request's diff can therefore invalidate
the Executor's approval. The refresh is also asynchronous, so an approval
issued immediately after requesting it can be attached to the old head and be
dismissed when the update lands.

The Executor must use the non-reviewing agent identity (`its-applekid`) for
`update-branch`, never the reviewing human identity (`its-everdred`):

```sh
gh api -X PUT "repos/$GITHUB_REPOSITORY/pulls/$PR/update-branch" \
  -f expected_head_sha="$(gh pr view "$PR" --json headRefOid --jq .headRefOid)"
```

After the request, wait until the pull request reports the new head SHA and
then re-read `reviewDecision`, mergeability, and the required checks. Do not
approve while the update is still pending. If the new head reports
`REVIEW_REQUIRED` while the latest code-owner review is `APPROVED`, the review
was invalidated by the refresh; wait for the head to settle and request a fresh
human approval. An empty attribution commit is not a remedy: it does not
contribute a reviewable change and does not move the relevant attribution.

This is an operational choice, not a ruleset exception: the gate retains
`require_last_push_approval` and has no bypass actors. The same procedure is
recorded on [#1405](https://github.com/aiur-team/aiur/issues/1405), the
umbrella issue for this gate's unsatisfiability cases.

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
`required_status_checks` rule matches the declaration exactly (the blocking
GitHub Actions contexts, their integration source, enforcement-on-create, and
strict status checks) — so a regressed gate fails CI visibly instead of
silently. It does not assert `bypass_actors`, which GitHub hides from read-only
tokens and the admin verifier audits at apply time. The drift check is not yet
a required status check: promoting it requires adding its context to the
reviewed declaration and applying the updated ruleset.

Aiur does not merge worker pull requests as part of the worker lifecycle. The
Executor's documented landing path, whether driven by a human or by an agent
acting as Executor, follows this same gate: it waits for the required GitHub
status checks and review conditions before issuing a squash merge. It does not
use auto-merge or a bypass actor, and it cannot merge a stale, pending, or
failing head. The application itself has no merge path to guard — the daemon
and CLI never issue a merge, they only observe and attribute `pr_merged`
events — so the CI drift check is the automated enforcement mechanism, not an
application-side guard. GitHub remains authoritative about whether a merge
occurred. The daemon's merge attribution is defense in depth, not permission to
bypass this gate.
`tracker.github.human_mergers` is a distinct, explicit allowlist for human
mergers. It does not inherit CODEOWNERS, `bot_account`, `trusted_accounts`, or
the dispatch `allowed_users`; absent configuration denies every merger and
raises a critical needs-attention alert. This repository permits only
`its-everdred`.

The declaration is the required steady state. The solo-operator release-merge
deadlock and any auditable, time-bounded maintenance procedure are tracked in
#1437 rather than encoded as a CI exception here.
