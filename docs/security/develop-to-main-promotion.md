# Develop → main release promotion

`develop` is the integration branch; `main` is released. Promoting `develop`
to `main` means opening a pull request from `develop` into `main` and merging
it through the human-only merge gate.

## Why this procedure exists

`.github/CODEOWNERS` names only `@its-everdred` (the human operator) and
`@its-applekid` (the agent account) as code owners. The `human-only-merge-gate`
ruleset requires `require_code_owner_review`,
`require_last_push_approval`, and `required_approving_review_count: 1` with no
bypass actors. With exactly one human code owner, the operator cannot approve
a PR they authored or last pushed — so a promotion PR authored by the human
deadlocks against the gate ([#1437](https://github.com/aiur-team/aiur/issues/1437)).

The satisfiable shape is the reverse attribution, proven end-to-end on
[#1696](https://github.com/aiur-team/aiur/pull/1696): **the agent account
authors and pushes the `develop → main` promotion, and the human operator
approves the exact head and merges.** Because the human is a code owner who
did not author the PR and was not the last pusher, a single human approval
satisfies all three rules without touching the ruleset and without the bot
approving anything. Every steady-state rule stays intact.

This is a convenience ticket, not a security exception: nothing here disables,
weakens, or toggles the gate, and the `merge ruleset drift` CI check keeps
asserting the full declaration. The auditable maintenance-window alternative
from #1437 was not adopted here because it would add privileged mutation,
expiry, and restoration machinery; this path preserves the gate as the
enforced steady state with no ruleset change.

## Procedure

Run the checked helper, which enforces the author identity and reuses or
creates the promotion PR:

```sh
scripts/promote-develop-to-main.sh
```

The script requires `GITHUB_TOKEN` (or `GH_TOKEN`) to resolve to the agent
account (`its-applekid`) when it creates or reuses the promotion PR. It
refuses to run on the human identity for that path: a promotion PR authored
by the human recreates the deadlock, because the human cannot approve their
own work. The `--verify` mode below makes no such requirement — it checks the
existing PR's author instead, so the human operator can run it with their own
token before merging. The create/reuse path then:

1. resolves the repository from `GITHUB_REPOSITORY` or the current remote;
2. computes how many commits `develop` is ahead of `main` and exits with
   "nothing to promote" when the delta is empty;
3. reuses an existing open `develop → main` pull request when one already
   exists, otherwise creates it as the agent account;
4. verifies the pull request's structure — base `main`, head `develop`,
   author is the agent account, state open — and prints the next steps.

### Human approval

1. Open the pull request URL the script printed.
2. Verify the PR is `develop → main`, authored by `its-applekid`, and that
   the diff is exactly the release content expected.
3. Approve the **exact current head**. `require_last_push_approval` and
   `dismiss_stale_reviews_on_push` mean a push to `develop` after the approval
   invalidates it; if `develop` moves, push nothing and re-approve the new head.
4. Confirm the blocking CI checks are green (the `merge ruleset drift`,
   `workflow security`, `build`, `test`, `lint`, `coverage`, `dialyzer`,
   `browser harness`, `streamdeck`, `layout release smoke` contexts; the
   `quarantined tests (non-blocking)` failure is expected and does not block).
5. Merge through the merge queue. Do not use a bypass actor, `--admin`, or an
   auto-merge shortcut.

### Pre-merge verification

Before merging, re-check that the gate is satisfied on the exact head. This
runs with any token (the operator's own token is fine); it verifies the PR's
author, base, head, and approval rather than the running identity:

```sh
scripts/promote-develop-to-main.sh --verify <pr-number>
```

The script exits non-zero and names the missing condition when the PR is not
yet mergeable (no approval, approval invalidated by a newer push, checks
blocking, or wrong base/head/author). Exit zero means the human approval is
current on the exact head and GitHub reports the PR mergeable.

## Why the agent account authors the PR

- `require_code_owner_review` is satisfied by the human's approval (the human
  is a code owner and did not author the PR, so this is not self-approval).
- `require_last_push_approval` is satisfied because the agent account pushed
  the head and the human approves a head they did not push.
- `required_approving_review_count: 1` is satisfied by that single human
  approval.
- The bot never approves anything, so the
  [CodeOwners.allowed?/1](human-only-merge-gate.md) review hole that #1398
  closed is not reopened.

The same reasoning is why a **human-authored** promotion cannot work: the
human cannot approve their own PR, the bot is the only other code owner, and
having the bot approve a human-only merge is precisely the hole the gate
exists to prevent. The promotion must therefore be authored by the agent
account every time.

## Failure handling

- **The gate still reports `BLOCKED` / `REVIEW_REQUIRED` after a fresh human
  approval on the exact head.** Run
  `scripts/diagnose-pr-merge-gate.sh <pr> <owner/repo>` to read GitHub's
  exact active-rule violation (see
  [human-only-merge-gate.md](human-only-merge-gate.md)); do not repeat the
  approval or open a ruleset window.
- **`develop` moved after the approval.** The approval was dismissed by
  `dismiss_stale_reviews_on_push`. Re-approve the new exact head; do not push
  an empty attribution commit as a workaround.
- **The script refuses because `GITHUB_TOKEN` is the human identity.** That is
  intentional. Re-run with the agent account token so the PR is authored by
  the agent account.

## Scope

This procedure resolves the solo-operator merge *convenience* deadlock
(#1437). Required status-check enforcement is a separate concern owned by
[#1466](https://github.com/aiur-team/aiur/issues/1466) and is not part of the
promotion procedure. The `human-only-merge-gate` declaration remains the
required steady state; no CI exception or ruleset carve-out is introduced
here.
