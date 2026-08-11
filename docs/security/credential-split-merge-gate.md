# Credential split under a human-only merge gate

## Decision

For a repository that enables GitHub's `require_last_push_approval`, Aiur uses
three distinct principals. The preferred bot credential is a GitHub App
installation token, with one App/bot identity assigned to pushes and a second
App/bot identity assigned to reviews. A human remains the merger and satisfies
the human-only rung of the gate.

| Principal | Allowed role | Configuration |
| --- | --- | --- |
| Push bot | Git transport pushes and agent-owned changes | `tracker.github.bot_account` and its push credential |
| Review bot | Reviews/approvals, never the last pusher | An operator-provided review credential outside Aiur's config; Aiur has no `tracker.github` setting for it today |
| Human | Final approval/merge | `tracker.github.human_mergers` |

Two principals cannot satisfy this gate. If the push bot also reviews, the
author and approver are the same principal. If the human reviews, the bot
credential split does not isolate the fleet's review traffic. Commit metadata
or API-authored objects do not substitute for Git transport attribution: the
push must be authenticated as the push bot, and the post-push last-pusher
identity must be checked before approval.

`aiur init` inspects classic branch protection and applicable rulesets when an
operator-only `AIUR_CI_READINESS_TOKEN` is available. When it sees
`require_last_push_approval` and the configured push bot or human merger is
missing, it warns during setup and links back to this decision. The review
credential is not part of that check because Aiur does not read a review-bot
setting from its config. When neither protection source can be read, the gate
is reported as unknown and init asks the operator to confirm it manually
instead of asserting that no gate exists. A CODEOWNERS or
ruleset carve-out is an explicit alternative that removes the three-principal
requirement; it is not inferred or silently enabled by init.

The working push recipe remains: authenticate the Git transport as the push
bot, verify the remote PR records that identity as last pusher, wait for fresh
CI, obtain the review-bot approval, then obtain the human approval and merge.
