---
title: "MP-R1-GHA-2: Pass github-access its settings and state root - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: brainstorm.md
ticket_id: MP-R1-GHA-2
complexity: 3
blocked_by: [MP-R1-GHA-1, MP-R1-C4-T02 (#3270), U5-T04 (#3297), U8-P22-T01 (#3489), U8-P22-T02 (#3490)]
base_sha: d2a022fad
date: 2026-10-09
---

# MP-R1-GHA-2: Pass github-access its settings and state root - Plan

## Summary

github-access stops reading aiur configuration. It reads one settings struct from a
registered provider. aiur's provider builds the struct from `Aiur.Config` on each call,
so hot reload and every path stay as they are. The credential half of
`Aiur.GitHub.Config` moves into github-access.

## Problem frame

Access modules call `Aiur.Config.settings/0` (`budget.ex` ~715, `credential_registry.ex`
~121), `Aiur.Config.workspace_root/0` with `Workspace.Layout` and `RepoBase`
(`quota.ex` ~1018-1130, `request_log.ex` ~165), `Config.Paths` (`resource_store.ex`),
`Config.Schema.GithubCredential` (`credential.ex`), `Config.Schema.Agent`
(`broker_timeout.ex`) and `Aiur.GitHub.Config.{repo,token,token_source,daemon_account,...}`
(`transport.ex` 59-73, `quota.ex` 1209, `host_command.ex` 97, `auth_preflight.ex` 335,
`app_token_refresher.ex` 263). Line numbers are at `d2a022fad`; U8-P22 splits move them.

## Requirements

- R3, R4, R7 (brainstorm.md).

## Key technical decisions

- **KD3 provider.** `Aiur.GitHub.Access.Settings` (new struct) and behaviour
  `Aiur.GitHub.Access.SettingsProvider` with `settings/0`. Registered by app env
  `config :aiur, :github_access_settings_provider, Aiur.GitHub.AccessSettings` (in
  `github`). Same registration pattern as C7-T06's app-env keys and C4-T02's registry.
- **Struct fields (directional):** `api_base_url`, `graphql_url`, `repo` (owner/name or
  nil), `credentials` (list of access-owned credential specs), `token_source` function,
  `budget` (limits, enabled?, broker path), `cache` (TTL caps, max entries),
  `state_root`, `request_log_dir`, `resource_store_path`, `probe_dir`,
  `alert_sink` (default `Signal.alert/2` after C7-T06/C5), plus fields GHA-3 adds.
  No field holds an aiur struct; credential specs are access-owned structs that the
  domain converts `Config.Schema.GithubCredential` into.
- **Credential half of `GitHub.Config` moves.** New `Aiur.GitHub.Access.Token`
  (`token`, `resolve_token`, `token_source`, `app_account`, `daemon_account`,
  `app_identity_issue`, `keyring_*`, `kill_os_process`). `Aiur.GitHub.Config` keeps
  delegating functions with the same names so the 45 outside callers do not change in
  this ticket (GHA-4 migrates them).
- **Paths stay byte-equal.** `AccessSettings` computes today's values: budget dir from
  `:github_budget_dir` app env or `~/.aiur/github-budget`; request log under
  `<repo-state>/github-quota/`; resource store from `Config.Paths`; probe dir from
  `Workspace.Layout.issue_workspace_path(root, "__github_quota_probe__")`.
- **Hot reload.** The provider is called per use where the code reads config per use
  today, and once at init where the code reads once today. No caching added.
- **Turn-sandbox root.** `Aiur.GitHub.Budget.SandboxRoots` (from C4-T02) reads the
  budget dir through the settings, not `Budget.state_dir/0` defaults.

## Implementation units

### U1. Characterization of today's paths and settings

**Goal:** Freeze the values the provider must reproduce.
**Dependencies:** none.
**Files:** `src/test/aiur/github/access_settings_test.exs` (new).
**Execution note:** Write and pass this on unchanged code first.
**Test scenarios:**
- With a fixture workflow (repo `o/r`, two credentials, budget limits) and temp HOME,
  record budget state dir, broker DB path, request-log path, resource-store path, probe
  dir, credential list order and token source; assert literal values.
- Budget disabled via app env → `enabled?` false.
- No workflow file → same fallbacks as today (no raise where today does not raise).

### U2. Settings struct, provider behaviour, static provider

**Goal:** The contract a standalone consumer uses.
**Dependencies:** U1.
**Files:** `src/lib/aiur/github/access/settings.ex`,
`src/lib/aiur/github/access/settings_provider.ex`,
`src/lib/aiur/github/access/static_settings.ex` (new);
`src/test/aiur/github/access/settings_test.exs`.
**Test scenarios:**
- Static provider returns the given struct; missing required field fails at build.
- Provider unset → github-access raises a clear error at first use, naming the app-env key.

### U3. aiur provider and access-module rewiring

**Goal:** Access modules read only `Settings`.
**Dependencies:** U2.
**Files:** `src/lib/aiur/github/access_settings.ex` (new, in `github`);
`src/lib/aiur/github/access/token.ex` (new); `src/lib/aiur/github/config.ex` (delegates);
the access files listed in the problem frame; `src/config/config.exs`.
**Approach:** Replace each listed call with a settings read. Keep function names and
public signatures of access modules. Move the credential half verbatim.
**Test scenarios:**
- U1 characterization passes unchanged after the rewire.
- Hot reload: change budget limit in the workflow file, call `Budget.guard_settings/0`
  again, new value returned (same as today). **Mutation:** cache settings at boot; fails.
- Standalone boot: start `ReadCache`, `ResourceStore` and `Budget` with the static
  provider and a temp `state_root`, without `Aiur.Application`; a deposit and a lookup
  work; files land only under the temp root. **Mutation:** leave one
  `Config.Paths` call in `resource_store.ex`; the file lands outside the root, fails.
- Existing suites green: `test/aiur/github/*`, `agent_github_guard_test.exs`,
  `workspace_and_config_test.exs`, `orchestrator/github_budget_pause_test.exs`.

### U4. Allowlist shrink

**Goal:** Remove the `GHA-2` rows from `github-access.tsv`.
**Dependencies:** U3.
**Files:** `scripts/components/allowlist/github-access.tsv`.
**Test expectation:** checker `--prune` leaves no stale `GHA-2` row; checker green.

## Risks

- **Silent path drift** would split one host ledger into two. Mitigation: U1 literal paths
  and the standalone-root mutation test.
- **Boot order.** The provider must be callable before `AppTokenRefresher` starts
  (`src/lib/aiur.ex` children ~358). It is a pure module function; no process.

## Definition of done

- `git grep -nE 'Aiur\.(Config|Workspace|RepoBase)\b|GitHub\.Config\.' -- <access files>`
  returns only doc comments and the `access_settings.ex` provider (which is in `github`).
- All U3 tests pass; mutation results in the PR body.
- `website/docs-app/apis/github.md` unchanged (no behaviour change).
