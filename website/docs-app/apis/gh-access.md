# Standalone GitHub access

`gh-access` wraps the real GitHub CLI with Aiur's host-local budget ledger,
byte-exact answer cache, concurrent-read coalescing and write invalidation.
It needs `gh`, Python 3 and a POSIX shell; it runs without an Aiur daemon.

## Install and run

The `aiur-cli` package includes `gh-access`. From a source checkout:

```sh
make -C packages/gh-access install PREFIX="$HOME/.local"
gh-access api repos/OWNER/REPO/issues/123
gh-access pr view 123 --repo OWNER/REPO --json title,body
```

Build outputs are generated locally. Separate npm/pip packages are deferred.
`make -C packages/gh-access test` runs the offline stub suite.

Standalone builds allow merge and approval commands. For a build that refuses
those commands, use `BUILD_FLAGS=--deny-merge` with `make install`.
Aiur's agent build always includes disposition, provenance, merge/approve and
undecidable-command policy. Standalone flags cannot disable that policy.

## Credentials and shared state

With no credential file, the real `gh` uses its own login. Inherited `GH_TOKEN`
and `GITHUB_TOKEN` are cleared before helpers start. To use a specific token,
set `AIUR_GITHUB_CREDENTIAL_FILE` to a restricted file containing it on the first
line. Only the real `gh` child receives that credential; helper processes do not.

By default, state is under `~/.aiur/github-budget`, shared with Aiur agents on
the same host. Answers and budget rows are separated by credential. Using a
different root creates a separate ledger and store. Preserve the same root and
credential to share state with agents. This is a policy boundary, not a
capability boundary: a process running as your user can still read your files.

| Setting | Default / effect |
| --- | --- |
| `AIUR_REAL_GH` | Real CLI path; otherwise walks PATH past known Aiur wrappers and its own directory. |
| `AIUR_GITHUB_CREDENTIAL_FILE` | Unset; use the real CLI's login. |
| `AIUR_GITHUB_BUDGET_ROOT` | `~/.aiur/github-budget`. |
| `AIUR_GITHUB_BUDGET_BROKER` | `gh-access-broker` beside the built wrapper. |
| `AIUR_GITHUB_BUDGET_CONSUMER` | `gh-access`, visible in broker usage. |
| `AIUR_GITHUB_BUDGET_ENABLED` | Enabled; `0` disables budget admission. |
| `AIUR_GITHUB_STATE_CACHE_ROOT` | `<budget root>/state-cache`. |
| `AIUR_GITHUB_STATE_CACHE_ENABLED` | Enabled; `0` disables cache reads. |
| `AIUR_GITHUB_STATE_CACHE_BYPASS` | `1` bypasses stored answers for this call. |
| `AIUR_GITHUB_STATE_CACHE_TTL_MS` | `60000`; below `1000` keeps no answers. |
| `AIUR_GITHUB_STATE_CACHE_WAIT_MS` | `15000`; follower wait before fetching independently. |
| `AIUR_AGENT_QUOTA_STATE_PATH` | Unset; set a private directory to record request/cache TSV events. |

## Cache and holds

The [shared-read contract](/apis/github-agent-cache) applies unchanged:
verdicts, including CI state and merge/review decisions, are never shared at
any age. Eligible repository GETs and selected JSON reads are kept byte for
byte for 60 seconds. Concurrent identical readers share one fetch; writes
invalidate affected answers. External changes require an Aiur delivery or poll
to invalidate early, otherwise eligible answers age out.

The [budget and holds contract](/apis/github-budgets) also applies. When an
enabled budget cannot coordinate (including a missing broker), the call fails
closed with a diagnostic. Explicitly disabling budget admission permits calls
without ledger writes. Disabling admission does not disable answer sharing.
