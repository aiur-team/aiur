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

`scripts/verify-human-only-merge-ruleset.sh` reads the live GitHub ruleset and
fails closed when any of those conditions drift. CI invokes it only after a
trusted push to `main` or `develop`, using the separate
`RULESET_AUDITOR_TOKEN` secret. That credential needs repository
Administration: read solely to inspect rulesets; it is never exposed to
pull-request code or the Aiur daemon.

The daemon's merge attribution is defense in depth, not permission to bypass
this gate: GitHub remains authoritative about whether a merge occurred.
