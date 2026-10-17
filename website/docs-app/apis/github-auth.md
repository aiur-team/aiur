# GitHub credentials and security

## Who Aiur trusts

| Source | Trust rule |
| --- | --- |
| Comment commands and review-driven rework | Accepted only from configured trusted/daemon/bot accounts, the repository owner, or CODEOWNERS logins verified in the current refresh. |
| Unresolvable CODEOWNERS | Failed teams contribute no members, including previously trusted members. Status/dashboard show the cause and age; sanitized comments remain visible to the Executor but untrusted bodies never enter agent digests or commands. Incomplete path ownership is unknown. |
| The bot identity | Cannot trigger its own work, except a distinct daemon App author filing a marked fixer authorized by `merge_policy.main_watch.on_red: dispatch_fixer`. Shared/PAT identities require human triage. |


## GitHub App authentication

The daemon authenticates with a short-lived GitHub App installation token when App credentials are configured, and falls back to the `GITHUB_TOKEN` personal access token otherwise.

When no App credentials are set, a `GITHUB_TOKEN` env var is preferred, then the `gh` keyring (`gh auth login`). Installation tokens identify the machine integration, are scoped to one installation's repositories, and expire after about an hour.

### Set up the App

Create a GitHub App under **Settings → Developer settings → GitHub Apps** and install it on the target repository with only these repository permissions.

| Permission | Grant |
| --- | --- |
| Contents | Read and write |
| Issues | Read and write |
| Pull requests | Read and write |
| Checks | Read (CI failure annotations) |
| Actions | Read for main-watch workflow attribution; write for canary and automatic failed-job reruns. |
| Administration, Secrets, Workflows | Never |

GitHub always adds `Metadata: Read-only` implicitly. Generate and download a private key (`.pem`); it can mint installation tokens for every repository the App is installed on, so keep it in a secure store.

### Configure the daemon

The daemon reads App credentials from the same `.env` the launcher sources; they are never written to `.aiur/config`.

| Variable | Purpose |
| --- | --- |
| `GITHUB_APP_ID` | The App's numeric id. |
| `GITHUB_APP_INSTALLATION_ID` | The installation id from the installation URL. |
| `GITHUB_APP_PRIVATE_KEY_PATH` | Path to the private-key PEM file; preferred. |
| `GITHUB_APP_PRIVATE_KEY` | Inline PEM alternative; use one or the other. |

`GITHUB_APP_PRIVATE_KEY_PATH` wins over the inline value so the key never appears in the process environment or shell history. When App credentials are configured, the daemon authenticates with a fresh installation token and ignores `GITHUB_TOKEN`.

A repository whose own `.env` sets a `GITHUB_TOKEN` (or any `GITHUB_APP_*` name) does not inherit the App from `~/.aiur/.env`; see [environment layering](/reference/configuration#environment-variables). Put App credentials in `~/.aiur/.env` for every repository the App is installed on, and in the repository `.env` when only that repository should use it.

The env token remains the fallback when no App credentials are present, followed by the `gh` keyring (`gh auth login`).

The keyring lookup (`gh auth token`) is bounded at boot, so a `gh` that stalls — a locked keyring prompting for a passphrase, a slow host, or a missing GUI credential agent — cannot hang the daemon with no log line.

The lookup logs before the shell-out and treats an unanswered lookup as "no keyring credential" (never a fatal error), naming `gh auth login` on timeout. The default bound is 5 seconds; set `AIUR_GH_KEYRING_TIMEOUT_MS` to a larger positive integer when a slow-but-succeeding unlock legitimately needs more time, or a smaller one to fail faster.

### Organization repository access during init

`aiur init` verifies that it can read the configured repository before it offers CI or label setup. GitHub deliberately returns `404 Not Found`, rather than `403 Forbidden`, for an inaccessible private repository, so a repository 404 is not proof that the repository or its base branch is missing.

Aiur checks the owner namespace and, when it can confirm an organization, reports an authorization diagnostic for the exact credential used by the probe.

The recovery depends on that credential:

- A classic PAT (`ghp_…`) needs the `repo` scope and SAML SSO authorization for the organization under **Settings → Developer settings → Personal access tokens → Tokens (classic) → Configure SSO**.
- A fine-grained PAT (`github_pat_…`) must use the organization as its resource owner, include the repository, and may need organization approval. A personal-owner token cannot be expanded to cover the organization's repositories.
- An OAuth token (`gho_…`) must belong to an OAuth app authorized for the organization. The `gh` CLI commonly uses a separate OAuth token from its keyring, so a successful `gh api` request does not prove that Aiur's configured token has the same access.
- A GitHub App installation token (`ghs_…`) requires the App to be installed on the repository with Contents read access.

If Aiur cannot confirm that the owner is an organization, it keeps the 404 ambiguous and asks you to verify both the repository name and token access.

### Token lifecycle

At boot the daemon signs an `RS256` JWT with the App private key and exchanges it at `POST /app/installations/{installation_id}/access_tokens`.

| Condition | Result |
| --- | --- |
| Refresh failure | Needs-attention `system.github_app_token.refresh_failed` alert with capped backoff retries. |
| Recovery | `system.github_app_token.refresh_recovered` clears the attention. |
| Grant beyond least-privilege | Needs-attention `system.github_app_token.permission_violation` alert. |

A supervised refresher re-acquires a fresh token before the hour-long expiry (5-minute safety margin) for the life of the daemon. The last known-good token keeps being used until it expires.

### Identity under App auth

An installation token authenticates as the App's bot user, `<app-slug>[bot]`, so every API-created comment, label, review, and pull request is attributed to that login.

| Setup | Requirement |
| --- | --- |
| `tracker.github.github_app.account` | Set to the App's bot login, `<app-slug>[bot]`. |
| `tracker.github.bot_account` | Keep set to the account agents use to push branches, open pull requests, and comment on tickets. |
| App account unset or not a bot login | Needs-attention `system.github_app_token.identity_mismatch` alert at boot. |

Self-loop suppression and PR command handling key off the daemon account: `github_app.account` under App auth, with `bot_account` as the fallback when App auth is not configured.

CODEOWNERS self-includes both the daemon account and the agents' `bot_account`. A wrong App login prevents self-write recognition; replacing `bot_account` with that login instead breaks agent-authorship checks.

Git commits keep their configured author; only GitHub API objects are authored by the App bot. Add the App bot login to `trusted_accounts` only if a gate needs to trust it beyond the configured daemon identity and built-in self-includes.

See `docs/security/daemon-token-posture.md` in this repository for the full setup narrative.


## What the agent guard governs

Agent processes do **not** inherit `GITHUB_TOKEN` or `GH_TOKEN`. The daemon scrubs them from every agent environment and instead writes the bot PAT to a
credential file (`~/.aiur/github-budget/agent-token`) that the `gh` guard
reads.

The wrapper injects the credential only into the real `gh` process it spawns
for a governed call, for the duration of that call — never into the agent's
environment and never into the sibling processes the wrapper launches.

So `env | grep -i -E 'GITHUB_TOKEN|GH_TOKEN'` in an agent shell returns nothing, and a bare `curl` to `api.github.com` from an agent workspace is unauthenticated.

This is a **policy boundary, not a capability boundary.** Agents run as the same OS user as the daemon, so an agent that deliberately goes looking can read the credential file, the shared budget database, or the operator keyring.

What the file removes is the raw token from the *environment* of every agent
process — where a dependency's build script, a `curl` one-liner, or a Node
fetch would inherit it — and the broker ledger counts the governed calls, not
every request a determined agent could make.

| Path | Governed by the guard |
| --- | --- |
| `gh` on the agent's PATH (the wrapper in the workspace `.aiur-runtime/bin`) | Yes — rate-limited, metered, and recorded in the broker ledger. |
| `git` on the agent's PATH (the wrapper in the workspace `.aiur-runtime/bin`) | Yes — destructive-command protection, not quota. |
| `gh`/`git` invoked by absolute path (`/usr/bin/gh`), or after a `PATH` reset | No — but unauthenticated, because the environment carries no token and the agent's `GH_CONFIG_DIR` is empty. |
| Any direct-HTTP client — `curl`, `Req`, a Python script, a Node fetch | No — unauthenticated from an agent workspace. |
| The daemon's own GitHub traffic | No — it runs as the daemon's own credential (the App installation token under App auth), a separate budget pool. |

## Human-review base checks

Human-review state writes compare the open PR with the configured base; stale heads also read fresh `mergeable` data for the exact PR head. State-label swaps add the target, revalidate current labels, then remove other state labels. Writes retry short local GitHub budget holds within the bounded wait policy.

Comparisons pin the configured `tracker.base_branch` and exact PR head to SHAs for the assessment; GitHub's lagging PR `baseRefOid` is not used as a freshness pin. Fresh `GET /repos/{owner}/{repo}/compare/{base}...{head}` reads check changes in both directions; rename checks include old and new paths.

A stale head approved at its current commit is refused only for a `CONFLICTING` verdict. Overlap alone does not require a push that dismisses approval. Queued or auto-merge-armed heads skip file comparisons because the queue tests the merge. Comments do not move queued PRs to rework (one GraphQL read, `rework_gate_merge_queue`); blocking reviews still do.

An unapproved stale head passes only with no conflicts or changed-file overlap since the merge base. Otherwise it returns `stale_review_base`. GitHub can lag its base SHA or report `UNKNOWN` while recalculating mergeability; those observations permit disjoint paths. A matching head's `CONFLICTING` verdict blocks the write.

Mismatched heads or base branches, malformed observations,
unreadable comparisons or a PR's own file list reaching GitHub's 300-file cap also block. A capped upstream or base comparison is not read as complete; the PR's paths are checked directly instead.

When a comparison is capped, one GraphQL read compares each PR path's object id at the merge base and the base tip, also attributed to `human_review_base_ancestry`. A malformed or failed answer blocks.

Comparison reads are attributed to `human_review_base_ancestry` and always contact GitHub because base movement can change verdicts. Orphan recovery reads `orphan_claim_mergeability` only after REST reports `mergeable: false`, and `orphan_claim_approval_state` after a stale-base write fails. No quota savings are claimed.

A head pushed after approval is classified once per approved/new head pair: one `pulls/{n}` read and up to three compare reads, attributed to `approval_carry`.

The approval carries only when the contribution diff (merge base to head) is identical, context included; hunk positions may shift with base edits above them. Any conflict resolution does not carry. The PR body `Tested head` must name the new head.

A carried approval posts a PR comment and a `ticket.<id>.pr.approval_carried` info alert. Any other verdict raises `stale_approved_pr_head` with the differing hunks. Unreadable or truncated comparisons count as changed.

For the next 10 handoffs after rollout, record the tested PR head, observed base SHA and overlap/conflict verdict. Count unsafe handoffs reaching review separately from harmless stale heads; the earlier 3-of-8 stale-base count is context, not an equivalent baseline for this narrower measure.


## Cloudflare tunnel boundary

Cloudflare is transport for the GitHub webhook, not an API Aiur calls.

| Boundary | Operator requirement |
| --- | --- |
| Origin | Point the tunnel at whatever address the daemon actually bound: `127.0.0.1` on the pinned `server.port` by default, or the `server.host` address if you pinned one. Pin `server.port` to a fixed value first — the default `0` binds a fresh OS port each boot. A `502` means the tunnel aims somewhere the daemon is not listening. |
| Public host | Serve the webhook at a hostname you control (`hooks.aiur.dev` here); without one, a quick tunnel (`cloudflared tunnel --url`) works for a single session. |
| Reachable path | Route only `/api/v1/github/webhook`; finish the ingress list with a catch-all `404`. |
| Network | No inbound firewall rule is needed or wanted because `cloudflared` dials out. |

The path scope and webhook signature are independent locks:

| Lock | Protects against |
| --- | --- |
| Path-only tunnel routing | Public access to the dashboard and every other route served on the daemon's bound address. |
| HMAC-SHA256 signature | Requests from anyone who does not know the shared webhook secret. |

Do not remove the catch-all `404`: the same origin serves the operator dashboard, and a host-wide tunnel would expose it to anyone who learned the hostname.
