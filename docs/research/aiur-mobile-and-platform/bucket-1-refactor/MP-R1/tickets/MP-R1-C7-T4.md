---
ticket_id: MP-R1-C7-T4
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Move the GitHub parts of the agent environment behind a registered contributor
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C7-T3, U5-typed-outcomes]
prior_units: [U4, U5]
prior_boundaries: ["#17 agent sandbox", GHB, GHC, GHD]
prior_features: []
prior_findings: [codebase-02]
size_owner: AGENT_CORE (agent_environment.ex 643, agent_process_log.ex 576; test agent_environment_test.exs 947); GH_GUARD (agent_github_guard.ex 541 — read only, not edited). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T4 — GitHub agent-environment contributor

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (migration step S6, second half).
- **User value:** none visible. The required `agent-sandbox` component stops depending on
  the optional `github` component (rule R-optional, `component-map.md` §2). Every agent
  still receives exactly the same environment, including every #2356 credential
  safeguard.
- **Deliverable:**
  1. Behaviour `Aiur.AgentEnvironment.Contributor` (PROPOSED
     `src/lib/aiur/agent_environment/contributor.ex`) with `port_env/2`,
     `shell_exports/2`, optional `repo_slug/0` and `agent_process_log_path/0`.
  2. `Aiur.GitHub.AgentEnvironmentContributor` (PROPOSED, in the `github` component)
     producing exactly the GitHub entries `AgentEnvironment` builds today.
  3. Contributors registered at the composition root
     (`config :aiur, :agent_environment_contributors, [Aiur.GitHub.AgentEnvironmentContributor]`).
  4. `AgentEnvironment` and `AgentProcessLog` reference no `Aiur.GitHub.*` and no
     `AgentGitHubGuard`.
- **Non-goals:** changing which variables an agent gets; changing the scrub deny-lists
  (they stay in the sandbox, see invariants); moving `AgentGitHubGuard` files; the
  `Workspace.Provisioner` support-module list (`provisioner.ex:13-14`, C7-T5).

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** C7-T3 (same files; repo-state paths already in `Config.Paths`).
- **Prior unit U5:** the budget/guard settings this ticket relocates (`Budget.guard_settings/0`,
  credential identity) are U5 (`GH_GUARD`, `GH_ACCESS`) territory. The U8 ledger says
  `GH_GUARD` starts only after "U5 access contract; GH_ACCESS API". Blocker
  `U5-typed-outcomes` = U5's exit (typed complete/held/unknown outcomes and the named
  shared API in `u8-release-007/proposal.md` "GH_ACCESS, GH_GUARD and GH_TRUST may
  proceed in parallel only after U5 names the shared API"). Prior U4 owns the agent
  runtime that consumes this env; no U4 file is edited.
- **RC-19:** no MP-E1-C1 path is touched.
- **Then:** MP-R7 (harness adapters) may start (S7 needs S6 complete).
- **Concurrent with:** C7-T1, C7-T2, C7-T6. Not with C7-T3/T5 (shared files).

## Verified starting point (base `45a290e3`)

GitHub references inside sandbox files (all must go):

- `agent_environment.ex:6-8` aliases `AgentGitHubGuard`, `GitHub.{AgentMarker, Budget, Credential}`,
  `GitHub.Config`.
- Port env (`workspace_env/2`, `:247-345`): `real_gh` (`:252`), `Budget.guard_settings/0`
  (`:253`), and entries `AIUR_AGENT_QUOTA_STATE_PATH`, `AIUR_AGENT_BIN`, `GH_CONFIG_DIR`
  (security invariant comment `:287-291`), `AIUR_REAL_GH`, `AIUR_GITHUB_LABEL_PREFIX`,
  the agent-marker var, `AIUR_GITHUB_REPO`, `AIUR_GITHUB_BUDGET_ROOT`,
  `AIUR_GITHUB_CREDENTIAL_FILE`, `AIUR_GITHUB_BUDGET_BROKER`, `_CONSUMER`,
  `_IDENTITY_KEY`, and seven budget limits (`:285-322`).
- Shell exports (`workspace_env_export_prefix/2`, `:404-469`): the same set as lines
  `:437-461` (`AIUR_REAL_GH=`, label prefix, repo slug, marker, `AIUR_AGENT_BIN`,
  `GH_CONFIG_DIR`, quota dir, budget root and credential file with `~` expansion,
  `unset AIUR_GITHUB_BUDGET_KEY`, publication credential, broker, consumer, limits).
- Helpers: `publication_credential_key/1` (`:473-476`), `publication_credential_identity/1`
  (`:478`), `configured_label_prefix/1` (`:560`), `agent_comment_marker/0` (`:584-586`),
  `agent_comment_marker_export/0` (`:588-596`), `configured_repo_slug/0` (`:598-603`),
  `remote_repo_slug_export/0` (`:577-582`), `repo_url/1` (`:623-633`, uses
  `GitHub.Config.repo/0` to choose the per-repo state node, else `neutral_repo_url/0`).
- `agent_process_log.ex:80` alias, `:562-575` `resolve_default_path/0` uses
  `GitHubConfig.repo/0` → `<repo state>/github-quota/agent-processes.tsv`, nil when unset.
- Deny-lists that **stay** in the sandbox: `agent_environment.ex:18-56`
  (`@github_credential_env_names`, `@app_credential_env_names` + pattern,
  `AIUR_GITHUB_BUDGET_KEY` at `:267`), applied in `unset_inherited_env` (`:257-269`) and
  `scrub_shell_prefix/1` (`:116-…`).
- Base fact: the GitHub entries are emitted **for every tracker kind** (no
  `tracker.kind` check in `workspace_env/2`); for Linear, `configured_repo_slug/0` yields
  `false` and `repo_url/1` the neutral URL.
- Tests: `src/test/aiur/agent_environment_test.exs` (947 lines, AGENT_CORE),
  `agent_process_log_test.exs`, `agent_github_guard_test.exs` (5,762, GH_GUARD).

## Chosen design

```elixir
defmodule Aiur.AgentEnvironment.Contributor do
  @callback port_env(workspace :: Path.t(), opts :: keyword()) :: [{charlist(), charlist() | false}]
  @callback shell_exports(workspace :: Path.t(), opts :: keyword()) :: String.t()   # newline-terminated lines
  @callback repo_slug() :: String.t() | nil            # optional; "owner/name"
  @callback agent_process_log_path() :: Path.t() | nil # optional
  @optional_callbacks repo_slug: 0, agent_process_log_path: 0
end
```

- `AgentEnvironment.workspace_env/2` = generic entries ++ each contributor's `port_env/2`
  ++ `unset_inherited_env` merge exactly as today (contributors cannot re-add a
  scrubbed name: the deny-list merge runs **after** contributors and wins).
- `workspace_env_export_prefix/2` inserts the concatenated `shell_exports/2` where lines
  `:437-461` sit; the generic lines (`AIUR_REAL_GIT`, `AIUR_AGENT_WORKSPACE`, scratch,
  scrub, trust, base branch, scheduler) keep their place. The scrub block stays last.
- `repo_url/1` asks contributors for `repo_slug/0` (first non-nil) and builds
  `https://github.com/<slug>.git` exactly as `:625-627`; none → `neutral_repo_url/0`.
  The URL format stays in the sandbox because it only feeds `Config.Paths.repo_state_path/1`.
- `AgentProcessLog.resolve_default_path/0` asks contributors for
  `agent_process_log_path/0`; GitHub's returns the current path; none → nil (as today
  for an unconfigured repo).
- **Registration** follows C7-T2's app-env pattern. The GitHub contributor is registered
  in every env, preserving "GitHub entries for every tracker kind".

**Invariants (security, #2356):**
1. No contributor can cause `GITHUB_TOKEN`, `GH_TOKEN`, `GH_ENTERPRISE_TOKEN`,
   `GITHUB_ENTERPRISE_TOKEN`, `MISE_GITHUB_TOKEN`, `GITHUB_APP_*` or
   `AIUR_GITHUB_BUDGET_KEY` to reach an agent. The deny-lists live in the sandbox and are
   applied whether or not any contributor is registered.
2. With the GitHub contributor registered, the resulting **environment** (variable →
   value map) for a fixed workspace and opts is identical to base, for both the port
   path and the shell-prefix path.
3. With no contributor registered (future build without `github`), the sandbox still
   produces a valid env without `GH_CONFIG_DIR`; this is acceptable only because no
   `gh` guard is installed either — recorded for MP-R1-C3 as capability
   `github` `unavailable: not_installed`.

## Implementation steps

1. Add the behaviour and the GitHub contributor; move the helper functions listed above
   into the contributor verbatim.
2. Replace the GitHub entries in `workspace_env/2` and `workspace_env_export_prefix/2`
   with contributor calls; keep deny-list code untouched.
3. Replace `repo_url/1` and `AgentProcessLog.resolve_default_path/0` lookups.
4. Register in `src/config/config.exs`.
5. Manifest: move the contributor into `github`; `agent-sandbox` loses its `github`
   allowlist rows.

Estimated production change: ~200 lines moved, ~50 new.

## Non-happy paths

- **Contributor raises:** today a raise in e.g. `GitHubConfig.bot_account/0` is rescued at
  `:478-…`; the rescue moves with the helper. A contributor that raises otherwise
  propagates exactly as the inline code would; no new rescue (behaviour-preserving).
- **Remote (SSH) workers:** shell path keeps `~` expansion lines `:447-450` byte-for-byte.
- **Ordering of exports:** variable assignment order within the GitHub block is kept;
  only its position relative to `AIUR_AGENT_WORKSPACE` may change. Semantics are
  verified by evaluating the prefix (test 2).
- **Privacy:** the agent env never gains a credential value; the credential-file path is a
  path, as today (`:308-312` comment).

## Compatibility and rollout

- No operator config change; one new application config key in `src/config/config.exs`.
- Rollback: revert.

## Verification

```bash
env -C src mise exec -- mix test test/aiur/agent_environment_test.exs test/aiur/agent_process_log_test.exs \
  test/aiur/agent_github_guard_test.exs test/aiur/workspace/hooks_test.exs \
  test/aiur/agent_environment/contributor_test.exs
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py   # MP-R1-C1 (PROPOSED)
```

New tests (`agent_environment/contributor_test.exs`):

1. "port env equals the base snapshot" — fixed workspace `/tmp/ws`, fixed opts
   (`repo_url`, `label_prefix`, `github_budget_identity`), stubbed `Budget.guard_settings`
   values; assert the sorted list equals a literal fixture captured from base `45a290e3`
   (fixture committed in the test). **Mutation:** drop `GH_CONFIG_DIR` from the
   contributor; fails.
2. "shell prefix yields the same environment" — run
   `bash -c "<prefix> env -0"` with `HOME` set to a temp dir; parse; compare to a literal
   fixture from base. **Mutation:** remove the `~` expansion line for
   `AIUR_GITHUB_CREDENTIAL_FILE`; fails.
3. "credential names are scrubbed even when a contributor emits them" — register a test
   contributor returning `{~c"GITHUB_TOKEN", ~c"x"}`; assert value `false` in port env
   and `unset GITHUB_TOKEN` effective in the shell prefix. **Mutation:** apply the
   deny-list before contributors; fails.
4. "no contributors still scrubs credentials" — empty registry; assert all deny-list
   names are `false`. Guard test (would pass at base by construction; marked as a
   regression guard in its name).
5. `agent_process_log_test.exs`: default path with GitHub repo configured equals
   `<root>/owner/name/github-quota/agent-processes.tsv`; nil with no contributor.
   **Mutation:** return the path with no contributor; fails.

Manual: foreground `scripts/aiurdev --test`; open one agent chat pane; send
`env | grep -iE 'GITHUB_TOKEN|GH_TOKEN'` as an Executor message asking the agent to run
it and report; the agent must report no output (AGENTS.md #2356 acceptance). Also
confirm a governed `gh issue view` still works inside the agent.

## Completion and handoff

- [ ] `git grep -nE 'Aiur\.GitHub|AgentGitHubGuard' -- src/lib/aiur/agent_environment.ex src/lib/aiur/agent_process_log.ex` returns only comments.
- [ ] Env snapshot tests pass and fail under mutation (PR body).
- [ ] Manual #2356 check recorded with the captured pane text.
- **Docs:** none required (no operator surface). If the PR touches
  `website/docs-app/apis/github.md` wording about the guard, it only re-links; read that
  page first (AGENTS.md).
- **Dependents:** MP-R7 (S7), C7-T5 (provisioner support modules), C7-T6.
