# Human-only merge gate

`human-only-merge-gate` protects both `main` and `develop`. It requires a
pull request, an approval from a CODEOWNER, and an approval by someone other
than the most recent pusher. Pushing a reviewable commit dismisses existing
approvals. It also requires every blocking CI check to pass, and it routes
merges through a merge queue. Strict status checks are deliberately disabled
(`strict_required_status_checks_policy: false`), so a pull request does not
have to be up to date with its target branch: the queue builds and tests each
entry against current `develop` before it lands. The ruleset has no bypass
actors.

The reviewed API declaration is
[`human-only-merge-ruleset.json`](human-only-merge-ruleset.json). An operator
with GitHub repository-administration permission applies or updates it with:

```sh
scripts/apply-human-only-merge-ruleset.sh
```

The declaration requires every blocking CI job to succeed, with GitHub Actions
fixed as the expected check source. The required `workflow security` check is
the CI job that runs the ruleset verifier itself; `build` and `test` are also
explicitly required alongside the remaining blocking jobs. Because
`strict_required_status_checks_policy` is `false`, those checks are satisfied
by the proposed head as it stands; being behind the target branch does not
withhold them. The declared `merge_queue` rule supplies the up-to-date test:
each queued entry is built on top of current `develop`, and only an entry that
passes there merges.

## Stale-base refresh procedure

**Refreshing the base is almost never necessary. Do not do it by default.**
The merge queue tests each entry against current `develop`, and strict status
checks are off, so a pull request that is merely *behind* its base needs no
action and will merge as-is. Refresh only when the pull request actually
conflicts with its base, or when a required check genuinely needs a rebuilt
base (for example a check that fails only against the older base). A reflexive
refresh on every "behind" signal burns queue cycles and destroys the Executor's
own approval for no gain — the exact failure
[#1597](https://github.com/aiur-team/aiur/issues/1597) exists to prevent.

When a refresh is genuinely warranted, use the procedure below.

If the pull request was armed with GitHub auto-merge, record that intent before
refreshing it. GitHub can silently clear `autoMergeRequest`, never announces the
cancellation, and does not restore it when a later rerun goes green. The
disarming is not reliably caused by the refresh itself — a base refresh does not
universally disarm an armed request (see
[#1649](https://github.com/aiur-team/aiur/issues/1649)) — so verify
`autoMergeRequest` after any refresh or rerun and re-arm when it has cleared.
Once the new head SHA is visible and its checks/mergeability have been re-read,
re-arm explicitly:

```sh
gh pr merge "$PR" --squash --delete-branch --auto
test "$(gh pr view "$PR" --json autoMergeRequest --jq '.autoMergeRequest != null')" = true
```

If the PR was not intentionally armed, leave it disarmed; the important rule
is that no refresh or rerun may leave the operator assuming an old auto-merge
request survived. Do not re-arm until the refreshed head has settled and the
approval/check state below has been evaluated.

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

The same rule applies to ordinary Git transport pushes. GitHub authenticates an
HTTPS push with the token, not the username written in the URL. The failed
#1401 recovery did use an `its-applekid` token-bearing URL, but its new commits
were tree-identical and changed zero files; they therefore never replaced the
earlier `its-everdred` reviewable-push attribution. Do not embed tokens in URLs.
Agents verify that `GITHUB_TOKEN` resolves to the configured bot account and use
the fail-closed helper recipe in `.claude/skills/using-aiur/dev-loop.md`, which
resets inherited helpers and refuses to fall back to the Executor keyring.

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
the strict-status-checks policy value) — so a regressed gate fails CI visibly
instead of
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

When a current human approval and green required checks still produce
`mergeStateStatus: BLOCKED` plus `reviewDecision: REVIEW_REQUIRED`, an Executor
should not repeat the approval. After the first ordinary merge/queue attempt is
refused, `.claude/skills/aiur-run/scripts/diagnose-pr-merge-gate.sh <pr>
<owner/repo>` reads the failed rule suite using the operator-only
Administration: read credential and prints GitHub's exact active-rule
violation. An agent acting as Executor emits that text as the needs-attention
`merge.rule-violation` alert described in the Executor skill. This replaces the
previous practice of making an `--admin` attempt solely to reveal the reason;
the script is read-only and never grants Administration authority to Aiur's
daemon or worker token.

`tracker.github.human_mergers` is a distinct, explicit allowlist for human
mergers. It does not inherit CODEOWNERS, `bot_account`, `trusted_accounts`, or
the dispatch `allowed_users`; absent configuration denies every merger and
raises a critical needs-attention alert. This repository permits only
`its-everdred`.

The declaration is the required steady state. The solo-operator release-merge
deadlock and any auditable, time-bounded maintenance procedure are tracked in
#1437 rather than encoded as a CI exception here.
