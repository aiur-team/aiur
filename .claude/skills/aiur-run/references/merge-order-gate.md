### Merge order gate

Run this before **every** `gh pr merge`, including `--admin` merges, which skip
any required check:

```bash
<loaded-aiur-run-skill>/scripts/check-stack-order.sh <pr-number> <owner/repo> \
  --repo-dir <fetched-clone> [--approved <approved-head-sha>]
```

Exit 0 is `PASS`. Exit 2 is `REFUSE` and exit 3 is `UNDECIDED`; both mean do
not merge. It refuses a PR whose base is not the integration branch, or whose
`blocked_by` blocker has not landed (closed `completed`, or its PR merged) and
whose merge commit is not in the PR head. There is no override flag: remove the
`blocked_by` edge if it no longer applies. It replaces reviewer-brief rule 5(d).

With `--approved <sha>` it also prints `RESTACK-ONLY <sha>..<head>` when every
commit since the approved head is an Aiur restack commit whose tree it
recomputed exactly (parents, `Aiur-Restack:` trailer, blocker head, integration
history). Only then may you re-approve after a dismissed approval, with a
one-line review body naming that range. Any other change needs a fresh review.
The daemon raises a critical `merge.out-of-order` alert when a PR merges ahead
of an unlanded blocker, but that is detective only.

