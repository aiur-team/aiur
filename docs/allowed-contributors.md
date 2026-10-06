# Allowed contributors

Allowed-contributor intake lets a repository name outside GitHub accounts, or
whole GitHub orgs, whose **new issues wake the Executor**. Each new issue from a
listed account produces exactly one `ticket.<n>.issue.opened.allowed_contributor`
record in the Executor wake feed
(`~/.aiur/repo/<owner>/<repo>/executor/<repo>.executor.wakes.ndjson`, topic class
`ticket.issue.opened.allowed_contributor`). The `aiur-run` skill tells the
Executor to triage these first and to treat their content as untrusted.

This is **intake, not dispatch authority**. An allowed contributor's issue is
dispatched exactly like an operator-filed one: when an account in
`tracker.github.allowed_users` applies the dispatch label (for example
`agent:todo`). A contributor who labels their own issue, or anyone else's,
dispatches nothing.

## Config

Set `tracker.github.allowed_contributors` in the operator's Aiur config:

```yaml
tracker:
  github:
    allowed_contributors:
      users: [583231, 9876543]
      orgs:
        - id: 9919
          login: github
```

User and org ids must be positive numeric int64 values, not strings or logins.
Org logins only address the membership API; the returned numeric org id must
still match. Unknown fields, invalid ids or logins, and conflicting logins for
one org id fail config validation with the dotted config key.

When this key is present, it is the **whole list** and Aiur never fetches the
file. `allowed_contributors: {}`, `allowed_contributors:` (null), or empty
`users` and `orgs` arrays explicitly admit nobody. Removing the key restores
the file fallback. Config changes take effect on reload or restart, raising
`allowed_contributors.changed` with the entries added and removed.

## The file fallback

When the config key is absent, Aiur reads `.github/ALLOWED-CONTRIBUTORS` on the
repository's **default branch**. The file has no alternate location. With no
config key and no file, the feature is off and nobody is admitted.

```text
# Trusted outside contributors. Logins after '#' are comments only.
user 583231            # octocat
user 9876543           # jane-doe

# Any active (public or private) member of these orgs.
org 9919 github        # id, then the org login used to call the API
```

- `user <id>` names one account by its **numeric GitHub user id**. Logins are
  never identities: they can be renamed, and a deleted account's login can be
  registered by anyone.
- `org <id> <login>` names an org by its numeric id. The login is used only to
  call `GET /orgs/{login}/memberships/{user}`. The response's
  `organization.id` must equal `<id>`, so a renamed org whose old name was
  re-registered by a stranger fails closed until you update the login.
- `#` starts a comment, and blank lines are ignored. No other forms exist:
  there are no teams, includes, wildcards, or nested lists.
- **A single malformed line disables the whole file.** Nobody is admitted, and
  an `allowed_contributors.invalid` alert names the commit.

Look up ids with the GitHub CLI:

```bash
gh api users/<login> --jq .id
gh api orgs/<org> --jq .id
```

## Precedence

When the config key is absent, Aiur reads the file only from the default branch reported by
`GET /repos/{owner}/{repo}`. It resolves that branch's head commit with
`GET /repos/{owner}/{repo}/branches/{branch}` and reads the file at that SHA.
It never uses the branch *name* as a ref, because a tag with the same name
could shadow it. It also never reads a PR branch, a fork,
`tracker.base_branch`, an issue, or a comment. Audit records and alerts name
the newest commit that touched the file. A PR that edits the file has no
effect until it is merged. Each merged change raises an
`allowed_contributors.changed` alert listing the added and removed entries and
the commit SHA.

An issue is admitted only when all of these hold:

1. it was **opened** in the tracked repository. Only `issues.opened` counts.
   Edits, labels, comments, reactions, reopenings, transfers out, and pull
   requests never produce a wake, whoever sends them;
2. GitHub reports its creator (`issue.user`, never the delivery's `sender`)
   with `type: "User"` and `performed_via_github_app: null` (a missing field
   counts as App-created), and the creator is not Aiur's own bot or daemon
   account. Issues filed through a GitHub App integration are never admitted;
3. it was created less than seven days ago, so a late redelivery of an old
   webhook cannot wake you again;
4. the creator's numeric id is listed, **or** they are an `active` member of a
   listed org (`state: active`, `role` `admin` or `member` — a billing manager
   is not a member — and `user.id` and `organization.id` matching);
5. that author has had fewer than 5 accepted wakes in the past hour. The count
   is persisted, so it survives a daemon restart.

Webhook deliveries must pass HMAC verification (`AIUR_GITHUB_WEBHOOK_SECRET`)
before any of this runs. Unsigned or mismatched deliveries are rejected with
401 and logged. The open-issue poll is a second producer for when webhooks are
missing. It considers issues created in the last 24 hours. A durable seen set
keeps it to one wake per issue across both producers and across restarts.

## Caching and failure

| What | Cached for | On failure |
| --- | --- | --- |
| Allow-list file | refreshed every 10 minutes | the previous snapshot is kept; with none, intake defers |
| Org membership, positive | 5 minutes | n/a |
| Org membership, negative (404, mismatch, pending, billing manager) | 60 seconds | n/a |
| Org membership, error (403, 429, 5xx, transport) | 60 seconds | never admits; the issue is deferred and re-evaluated on a later sighting |
| Wake publish | n/a | an accept that fails to publish is deferred and retried, never audited as accepted, and does not spend the author's hourly cap |

Membership is checked over REST with the operator's GitHub credential. That
credential must be able to see the org's membership: for private members, the
operator account must belong to the org. If it cannot see the membership, the
check fails closed.

## Revoking

- **Config entries:** remove the user id or org entry and reload config (or
  restart). Set `allowed_contributors: {}` to revoke everyone without enabling
  the file fallback.
- **File account:** delete its `user` line and merge to the default branch. The
  change takes effect at the next refresh, within 10 minutes.
- **One org member:** remove them from the org. They stop counting once the
  5-minute positive cache expires.
- **Everything:** delete the file, or make it unparseable, and merge.

Revocation affects new issues only. Wakes already delivered stay in the feed,
and an issue already labelled for dispatch stays labelled.

## Audit

Every accept, reject, and deferral is appended to
`~/.aiur/repo/<owner>/<repo>/executor/<repo>.allowed-contributors.audit.ndjson`
and logged by the daemon. Each record carries the issue number, the numeric
author id, the reason, `allowlist_source` (`config` or `file@<sha>`), the
allow-list commit SHA (`null` for config), and the producer (`webhook`
or `poll`). The seen set and the last-shown allow-list SHA live beside it in
`<repo>.allowed-contributors.json`.

## Threat model

- Random accounts cannot produce a wake: identity is the numeric id from an
  authenticated API response or an HMAC-verified payload, never a login taken
  from issue text.
- An allowed contributor cannot extend trust. Nothing they write is read as
  configuration. Config is operator-owned; the fallback file changes only
  through the default branch.
  Protect `.github/ALLOWED-CONTRIBUTORS` with CODEOWNERS and branch
  protection so that only repository admins can merge changes to it.
- A compromised allowed account can produce at most 5 wakes an hour and
  cannot dispatch anything.
- Issue content from allowed contributors is untrusted input. Aiur wraps it as
  external content in agent prompts, and the Executor is told never to follow
  instructions found in it.
