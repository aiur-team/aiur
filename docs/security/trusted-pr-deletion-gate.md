# Trusted PR deletion gate rollout

`trusted-pr-deletions.yml` is a `pull_request_target` workflow. GitHub runs it
from the protected base branch, and checkout pins the script to the event's
base commit. The workflow fetches `refs/pull/<number>/head` as Git data and
checks that its commit matches the event head. It never checks out, sources,
or executes pull-request files. The script compares merge base to PR head and
refuses more than 50 net file deletions.

The workflow publishes commit status `aiur/trusted-pr-deletions` on the PR
**head SHA** through a dedicated GitHub App. The Actions job itself is not the
required gate: GitHub does not attach a `pull_request_target` job check to the
head commit in the way a branch ruleset requires. A missing token, fetch
failure, moved head, or failed status post cannot produce a success status.

## Activation order

1. Merge the reviewed workflow and checker into the protected base. Do not
   require the new context yet. This gives `pull_request_target` a base-owned
   workflow and script to run.
2. Create a dedicated GitHub App with **Commit statuses: Read and write** and
   install it only on the repository. Keep it separate from Aiur's daemon App.
   Set repository variable `AIUR_DELETION_GUARD_APP_CLIENT_ID` to its Client ID
   and secret `AIUR_DELETION_GUARD_APP_PRIVATE_KEY` to its private key. The
   workflow requests only `permission-statuses: write` from the installation.
3. Open a disposable PR with 51 real file deletions. Confirm that
   `aiur/trusted-pr-deletions` is a **failure on its head SHA**, authored by
   the dedicated App. Also check a PR with 50 deletions and a fork PR with no
   deletions for success. Check that the workflow's checkout log names the
   protected base SHA and no PR-head checkout occurs.
4. Update `docs/security/human-only-merge-ruleset.json`: append
   `{"context":"aiur/trusted-pr-deletions","integration_id":<dedicated App ID>}`
   to `required_status_checks`. Preserve `strict_required_status_checks_policy:
   false`. Apply with `scripts/apply-human-only-merge-ruleset.sh`, then run
   `scripts/verify-human-only-merge-ruleset.sh` and the read-only live verifier.
   Do not use the GitHub Actions integration ID; the rule must bind the
   dedicated App so another token cannot impersonate the context.
5. Recheck the 51-deletion PR from a non-bypass actor: GitHub must report it
   unmergeable. The existing Executor bypass actor can override repository
   rules and must respect the same deletion policy operationally; the status
   rule alone cannot constrain that actor. Only then is #2803's server-side
   enforcement for ordinary merges proven. Repeat the setup in Khala's
   repository with its own installation, secrets, workflow, and required status rule.

The workflow listens for `opened`, `synchronize`, `reopened`, `edited`, and
`ready_for_review`. A head update gets a new SHA and status; a base-target
edit gets a new check. A normal fast-forward of protected `main` does not
change the merge base of a fixed PR head, so it does not change the set of
files the PR itself deletes. The existing ruleset prohibits rewriting or
deleting `main`, which is the condition for retaining its non-strict policy.

Until the App status is live, source pin is verified, and a blocked PR is
proven unmergeable under the required rule, this workflow is only a staged
gate. The PR-head CI check in #2835 is an additional signal, not the
authoritative gate.
