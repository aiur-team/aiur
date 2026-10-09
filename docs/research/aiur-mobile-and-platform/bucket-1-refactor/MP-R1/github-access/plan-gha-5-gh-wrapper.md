---
title: "MP-R1-GHA-5: Build the agent gh wrapper as a standalone gh-access executable - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: brainstorm.md
ticket_id: MP-R1-GHA-5
complexity: 3
blocked_by: [MP-R1-GHA-1, U8-P23-T01 (#3493), U8-P23-T02 (#3494), MP-R1-C7-T04 (#3298)]
base_sha: d2a022fad
date: 2026-10-09
---

# MP-R1-GHA-5: Build the agent gh wrapper as a standalone gh-access executable - Plan

## Summary

Group the parts of the agent `gh` guard into `core` (budget lease, shared answer store,
coalescing, pagination, holds, credential injection) and `aiur-policy` (dispatch
disposition #1793, provenance marker #2501, merge/approve denial, undecidable-command
refusal). Build two artifacts from the parts: aiur's installed `gh`, byte-identical to
today, and a standalone `gh-access` that any agent or tool can put in front of `gh`
without aiur. Ship the standalone build with its own docs page. Move the install
mechanics that are not workspace layout from `AgentGitHubGuard` into github-access.

## Problem frame

`src/priv/github_quota_guard.sh` (3,403 lines) and `src/priv/github_budget.py` (1,112)
are the only language-neutral part of the GitHub layer and the part with an immediate
second consumer: Executor sessions and background agents on the same host run plain
`gh` and spend the bot budget unseen (brainstorm.md Q1, A3). U8-P23-T01 splits the guard
into parts of at most 500 lines and concatenates them at build time; U8-P23-T02 does
the same for the broker. This ticket uses those parts.

## Requirements

- R5, R7, R8 (brainstorm.md); KD4, KD5, KD6, KD8.

## Key technical decisions

- **Build-time composition (KD5).** A parts manifest lists every part with a group tag
  (`core` or `aiur-policy`) in today's order. aiur build = all parts. Standalone build =
  `core` parts plus `policy-none.sh` (a part that defines the policy functions the core
  calls as no-ops returning "allow"). No runtime `source`, no hook file.
- **Byte-identical aiur artifact.** A test hashes the aiur build and compares it to the
  committed hash of the pre-change concatenation. Any reordering fails it.
- **Defaults for standalone use.** State root `~/.aiur/github-budget` (KD4: one ledger
  and one answer store per credential per host, shared with aiur agents). Real `gh`
  found by the existing PATH walk (`is_guard_gh` skips wrappers). No
  `AIUR_GITHUB_CREDENTIAL_FILE` → the real `gh` uses its own login, with
  `GH_TOKEN`/`GITHUB_TOKEN` cleared for that child exactly as today (line ~93).
  Broker path: `AIUR_GITHUB_BUDGET_BROKER`, else the `gh-access-broker` beside the
  wrapper.
- **Verdict refusals are core.** `cache_volatile_fields`, `cache_unsafe_rest_endpoint`
  and the "never shared at any age" rows stay in core parts; the standalone build refuses
  the same reads (R8).
- **Credential rule (KD8).** The standalone wrapper never exports a token to its
  environment or to sibling processes; the credential reaches only the real `gh` child.
  `GITHUB_TOKEN`/`GH_TOKEN` scrubbing of aiur agents stays in agent-sandbox (C7-T04).
- **Install mechanics.** `install_host/…`, `host_bin_dir/0`, `agent_token_path/0`,
  `ensure_agent_token_file/…`, `budget_broker_path/…`, `real_gh/…` move to
  `Aiur.GitHub.Access.Wrapper` (github-access); workspace placement
  (`bin_dir/1`, `gh_config_dir/1`, `quota_dir/1`, `install/…`,
  `missing_workspace_support/…`) stays in `AgentGitHubGuard` (agent-sandbox) and calls
  the facade. `github_push_guard.sh` (the `git` guard) stays aiur policy.
- **Distribution.** In this ticket: `packages/gh-access/` with the build script, the two
  built files as release outputs (not committed), a `make install PREFIX=` target, and
  docs. An `aiur gh-access install` verb in `aiur-cli` only if Kevin answers Q2 that way;
  npm/pip publishing is deferred (brainstorm.md §7).

## Implementation units

### U1. Parts manifest and group tags

**Files:** `src/priv/github_guard/parts.txt` (or the manifest U8-P23-T01 created, tagged);
`src/priv/github_guard/policy-none.sh` (new); `src/lib/aiur/agent_github_guard.ex`
(reads the manifest at compile time as U8-P23-T01 does).
**Test scenarios:**
- aiur build hash equals the committed pre-change hash. **Mutation:** swap two parts;
  fails.
- Every part is tagged; an untagged part fails the build test.

### U2. Standalone build and shell test suite

**Files:** `packages/gh-access/build.sh`, `packages/gh-access/Makefile`,
`packages/gh-access/test/standalone_test.sh` (new); CI job entry next to the existing
shell guard tests.
**Test scenarios (stub `gh` that logs calls and prints fixed JSON):**
- `gh-access api repos/o/r` twice within the TTL → one stub call; second output
  byte-equal; `agent-cache.tsv` records `hit`. **Mutation:** build without the state
  cache part; two stub calls, fails.
- `gh-access pr view 1 --json statusCheckRollup` twice → two stub calls (verdict never
  shared, R8).
- Two concurrent identical reads → one stub call (coalescing).
- `gh-access pr merge 1` → passed to the stub (no aiur policy); the aiur build refuses
  it. Both asserted.
- `gh-access issue create --title x` without a dispatch label → allowed standalone,
  refused by the aiur build (#1793).
- Broker ledger row written with consumer `gh-access` default; `AIUR_GITHUB_BUDGET_ENABLED=0`
  → no ledger write, call still runs.
- No credential file and caller `GH_TOKEN=secret`: the stub child sees `GH_TOKEN`
  empty and `env` of a sibling process launched by the wrapper has no `secret`.
- Missing broker → call runs unbudgeted with today's diagnostic line (fail-open
  behaviour of the guard unchanged).

### U3. Install mechanics into github-access

**Files:** `src/lib/aiur/github/access/wrapper.ex` (new);
`src/lib/aiur/agent_github_guard.ex`; `src/lib/aiur/github/host_command.ex`;
`src/test/aiur/agent_github_guard_test.exs` (or its U8 split parts).
**Test scenarios:**
- Workspace install produces the same three files with the same modes as base (hash and
  mode check). **Mutation:** install the standalone build; hash differs, fails.
- Host install path and agent-token file path unchanged; token file mode 0600.

### U4. Docs

**Files:** `website/docs-app/apis/gh-access.md` (new page: what it caches, what it
never caches, budget and holds, env table copied from github.md "Shared agent reads",
install, how to share a ledger with aiur agents, what it does not protect — "policy
boundary, not a capability boundary"); `website/docs-app/apis/github.md` (one link);
`packages/gh-access/README.md`.
**Test expectation:** docs build passes; `scripts/check-config-docs.py` unaffected.

## Risks

- **Policy part dropped from aiur's build** would remove the merge gate for every agent.
  Mitigation: U1 byte-identity hash and U2's aiur-build refusal assertions.
- **Two answer stores for one credential** if a standalone user sets a different root.
  Documented, not prevented.

## Definition of done

- Both builds produced in CI; U2 suite green and failing under mutation; aiur install
  byte-identical; docs page live in the docs build (not deployed: Netlify builds are
  on request only).
