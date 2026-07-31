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
`RULESET_AUDITOR_TOKEN` secret. GitHub omits `bypass_actors` from ruleset
responses unless the caller has ruleset write visibility, so a fine-grained
token used for this audit needs repository Administration: write even though
the workflow performs only read operations. The token must be an isolated
auditor credential available only to trusted protected-branch pushes; it is
never exposed to pull-request code or the Aiur daemon.

The verifier requires both `conditions.ref_name.exclude` and `bypass_actors`
to be present and exactly `[]`. Missing or `null` properties fail the audit:
an omitted `bypass_actors` property means the credential cannot prove that
the live ruleset has no bypass.

The daemon's merge attribution is defense in depth, not permission to bypass
this gate: GitHub remains authoritative about whether a merge occurred.
`tracker.github.human_mergers` is a distinct, explicit allowlist for human
mergers. It does not inherit CODEOWNERS, `bot_account`, `trusted_accounts`, or
the dispatch `allowed_users`; absent configuration denies every merger and
raises a critical needs-attention alert. This repository permits only
`its-everdred`.

The verifier intentionally has no maintenance-window override. Temporarily
disabling last-push approval creates the stale-approval merge path this control
exists to prevent, so operators must stop toggling it even for legacy PRs.
