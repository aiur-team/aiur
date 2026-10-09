---
title: "MP-R1-GHA-1: Declare github-access as its own component - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: brainstorm.md
ticket_id: MP-R1-GHA-1
complexity: 2
blocked_by: [MP-R1-C7-T06 (#3301)]
base_sha: d2a022fad
date: 2026-10-09
---

# MP-R1-GHA-1: Declare github-access as its own component - Plan

## Summary

Split the `github` entry in `components.json` into `github-access` and `github`. Manifest
and allowlist only; no Elixir, shell or Python change. After this ticket the checker
knows which files are the access layer and fails CI on any new access → domain edge.

## Problem frame

`components.json` has one `github` entry with facades `*`. The access layer cannot get a
boundary until the checker can name it (brainstorm.md §1, R1, R2). C7-T06 (#3301) first
writes the census-derived facade list for `github`; this ticket splits that entry.

## Requirements

- R1, R2 (brainstorm.md). Ownership of `src/priv/github_budget.py` and
  `src/priv/github_quota_guard.sh`, which no component owns today.

## Key technical decisions

- **Path globs, not file moves.** github-access paths are globs that also match the
  parts U8 splits create: `src/lib/aiur/github/{transport,errors,graphql_errors,graphql_cost,endpoint_policy,quota,request_log,request_origin,budget,budget_broker,budget_ledger,broker_timeout,local_hold,credential,credential_registry,credential_selector,credential_headroom,credential_usage,app_credentials,app_token,app_token_refresher,auth_preflight,host_command,connectivity,read_cache,resource_store,resource_events,resource_fetch,membership_access,agent_cache,agent_cache_bridge,cycle_fetch_cache}*.ex`, `read_cache/**`, `resource_store/**`, `quota/**`, `budget/**`, `transport/**`, plus `src/priv/github_budget*.py` and `src/priv/github_quota_guard*`. Re-resolve against the head at ticket start (U8-P22/P23 may have landed). The checker's glob semantics decide the exact spelling.
- **Overlap rule.** `github`'s `src/lib/aiur/github/**` glob would also match access
  files. Use the checker's existing precedence (most specific owner) if it has one;
  otherwise replace `github`'s glob with an explicit domain list (brainstorm.md §4.2).
  Verify with `ownership()` in `scripts/check-components.py`; a file with two owners must
  fail the ownership rule, not pass silently.
- **The `config.ex` credential half stays in `github` for now.** `config.ex` is one file; it stays in
  `github` until GHA-2 extracts the credential half. The resulting access → `GitHub.Config`
  edges go into the allowlist with reason `MP-R1-GHA-2`.
- **Layer and kind.** `github-access`: layer 2, kind `optional` (same as `github`),
  `requires: [kernel, signal]`, `optional: []`. `github`: adds `github-access` to
  `requires`. `owns.env` moves `AIUR_GITHUB_BUDGET_*`, `GITHUB_TOKEN`, `GH_TOKEN`,
  `GITHUB_APP_*` to github-access; `owns.state` lists `~/.aiur/github-budget/`,
  `<repo-state>/github-quota/`, `github_resources.json`.
- **Facades.** `facade_pending: MP-R1-GHA-4`; the facade list is today's census
  restricted to access modules that domain or other components call (C7-T06 output).
- **Allowlist baseline.** New `scripts/components/allowlist/github-access.tsv` with
  today's access → outside violations, each with a reason naming the GHA ticket that
  removes it (GHA-2, GHA-3, GHA-5) or the existing ticket (C7-T06 for `Alerts`).
  `--growth-base` must see ticket reasons on every added row.

## Implementation units

### U1. Manifest entries

**Goal:** `github-access` entry; `github` entry narrowed and depending on it.
**Requirements:** R1, R2.
**Dependencies:** C7-T06 merged.
**Files:** `components.json`; `scripts/components/allowlist/github-access.tsv` (new);
`scripts/components/allowlist/github.tsv`.
**Approach:** Edit by hand, then `python3 scripts/check-components.py --format`. Move
rows of `github.tsv` whose source file is now access-owned into `github-access.tsv`.
**Patterns to follow:** existing `github-listeners` entry; C7-T06's entry.
**Test scenarios:**
- Every file under `src/lib/aiur/github/` has exactly one owner (checker ownership rule).
- `src/priv/github_budget.py` and `src/priv/github_quota_guard.sh` are owned by
  github-access.
- The full checker run passes with the new allowlist.
**Verification:** `python3 scripts/check-components.py --require-elixir` and
`bash scripts/test-check-components.sh` pass.

### U2. Checker fixture for the access rule

**Goal:** Prove a new access → domain reference fails.
**Requirements:** R1.
**Dependencies:** U1.
**Files:** `scripts/components/fixtures/access_to_domain_fails/` (new: `components.json`,
two `.ex` files); `scripts/test-check-components.sh`.
**Approach:** Mirror `fixtures/undeclared_dependency_fails`: component `acc` (layer 2,
requires kernel) references a module of component `dom` that requires `acc`. Expect
failure with rule `declared` (and `down` if layers differ).
**Test scenarios:**
- Fixture fails with the access → domain reference. **Mutation:** add `dom` to `acc`'s
  `requires`; the fixture then passes, so the test fails.
- A doc-comment mention of the domain module passes (mirror `doc_mentions_ignored`).
**Verification:** `bash scripts/test-check-components.sh` green.

## Risks

- **Two owners for one file** if the glob precedence is not what is expected. Mitigation:
  the ownership test in U1.
- **Allowlist grows.** It does, once, by moving rows from `github.tsv`; net count across
  both files must not increase. Record before/after counts in the PR body.

## Definition of done

- Checker green; fixture fails under mutation; net allowlist count not increased.
- `component-map.md` row `github-access` matches the manifest (docs-sync rule of
  MP-R1-C10-T04 if merged).
