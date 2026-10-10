# After the blocker merges: restack

A live dependent owns its restack; the daemon handles idle dependents only.
On `ticket.<B>.pr.merged`, inspect the actual blocker PR number and merge SHA
from delivered facts. B in the commands below is the PR number, which may differ
from the blocker ticket number. Use `AIUR_BASE_BRANCH` as the integration branch.
Do not substitute a plain merge: squash history can conflict on blocker-introduced
lines the dependent edited.

Commit any local work first. Record the dependent HEAD and push a unique rescue
ref before resolving conflicts. Require git 2.40+; older git cannot use the custom
merge base. Use the existing fail-closed agent credential push recipe in dev-loop.

1. Fetch the integration branch and `refs/pull/<B>/head` into private refs.
   The PR head ref survives deletion of the blocker's branch.
2. Skip if the blocker merge SHA is already an ancestor of HEAD. Otherwise
   compute L = `merge-base(HEAD, blocker-head)`.
3. Compute T = `merge-tree --write-tree --merge-base=L base HEAD`.
   On success create C = `commit-tree T -p HEAD -p base`, with the trailer
   `Aiur-Restack: blocker=#<B> blocker-head=<F> base=<base SHA>`.
4. Plain-push C to the dependent's actual branch, then fast-forward the local
   checkout to C. A rejected push means the remote moved: fetch and inspect
   that work before retrying. Never force a plumbing restack.

Example after substituting the verified blocker PR number:

```bash
workspace="$AIUR_AGENT_WORKSPACE"
blocker_pr='<B>'
branch="$(git -C "$workspace" branch --show-current)"
dependent="$(git -C "$workspace" rev-parse HEAD)"
git -C "$workspace" fetch origin \
  "+refs/heads/$AIUR_BASE_BRANCH:refs/aiur/restack/base" \
  "+refs/pull/$blocker_pr/head:refs/aiur/restack/blocker" || exit
base="$(git -C "$workspace" rev-parse refs/aiur/restack/base)" || exit
blocker="$(git -C "$workspace" rev-parse refs/aiur/restack/blocker)" || exit
merge_base="$(git -C "$workspace" merge-base "$dependent" "$blocker")" || exit
# Stop on any error; a conflict must never reach commit-tree or push.
if tree="$(git -C "$workspace" merge-tree --write-tree --merge-base="$merge_base" "$base" "$dependent")"; then
  message="Restack after #$blocker_pr merged

Aiur-Restack: blocker=#$blocker_pr blocker-head=$blocker base=$base"
  restack="$(git -C "$workspace" commit-tree "$tree" -p "$dependent" -p "$base" -m "$message")" || exit
  git -C "$workspace" push origin "$restack:refs/heads/$branch" || exit
  git -C "$workspace" merge --ff-only "$restack"
fi
```

On conflict, inspect the paths, preserve a pushed rescue ref, then use
`git -C "$workspace" rebase --onto "$base" "$merge_base"`. Resolve each hunk
preserving both contracts. Record the expected remote head before the rebase
and push with an explicit `--force-with-lease=refs/heads/<branch>:<expected SHA>`.
The push must reject competing work. Report that you rebased, request fresh
review, and let the branch event pipeline publish any force-push observation.

If you receive `ticket.<D>.restack.conflict`, the daemon pushed nothing.
Fetch its blocker PR and main refs and follow the same conflict recipe.
The trailer is evidence for later verification; it never grants approval by itself.

Idle restacks leave a private pending ref; before_run consumes it with a local
fast-forward before merging the integration branch. Divergent local work skips
that hook and remains for the resumed agent to reconcile.
