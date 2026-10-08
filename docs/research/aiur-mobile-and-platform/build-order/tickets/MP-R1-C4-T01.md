---
ticket_id: MP-R1-C4-T01
feature_id: MP-R1
chunk_id: MP-R1-C4
bucket: 1-refactor
title: Registered semantic config checks - Aiur.Config.validate!/0 stops calling GitHub, Claude and Opencode config modules
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T02]
prior_units: [U8]
prior_boundaries: ["CFG #2", "GHC #5", "CLD #22", "OC #24"]
prior_features: []
prior_findings: []
size_owner: "src/lib/aiur/config.ex: U8 CONFIG 'Configuration' (1,462 lines at release; split) — this ticket must shrink it"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C4-T01 — Registered semantic config checks

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C4 (config ownership by registration).
  Step S9. Prior inversion class `config->schema-registration`.
- **User value:** none visible. Config (L0) stops naming feature modules; adding or
  removing a tracker or harness no longer edits `Aiur.Config`.
- **Deliverable:**
  - PROPOSED behaviour `Aiur.Config.SemanticCheck`:
    `@callback applies?(settings) :: boolean()` and `@callback check(settings) :: :ok | {:error, term()}`.
  - Ordered registry in `src/config/config.exs`:
    `config :aiur, :config_semantic_checks, exclusive: [...], always: [...]`.
  - `Aiur.Config.validate_semantics/1` (`config.ex:1311-1316`) and
    `validate_kinds_and_secrets/1` (`:1319-1345`) rewritten to evaluate the registry:
    **exclusive** group = first check whose `applies?/1` is true runs, others skip (exact
    `cond` semantics); **always** group runs in order.
  - Checks moved next to their owners: `Aiur.GitHub.Config.SemanticCheck`,
    `Aiur.Claude.Config.SemanticCheck`, `Aiur.Opencode.Config.SemanticCheck`; the
    tracker-kind, agent-kind and Linear branches move to `Aiur.Tracker.SemanticCheck`
    and `Aiur.CodingAgent.SemanticCheck` (they keep their exact error atoms).
- **Edges removed (measured at base with the prior walker):** `Aiur.Config →
  Aiur.GitHub.Config` (`config.ex:1337`), `→ Aiur.Claude.Config` (`:1340`),
  `→ Aiur.Opencode.Config` (`:1314`). The `Aiur.CodingAgent` reference at `:1327` moves
  out too, but `Aiur.Config → Aiur.CodingAgent` stays allowlisted: `config.ex` still
  references it at `:319`, `:396`, `:495`, `:1405-1413` (C4-T03 and MP-R7).
- **Non-goals:** changing which checks run or their order; fixing the quirk below;
  Ecto schema embeds (stay literal, see C4-T05).

## Dependencies and blockers

- DESIGN-R1 §1 ("`.aiur/config` keys keep their names and meaning"); C1-T02 (allowlist,
  so the removed edges are proven by stale-entry deletion once C1-T05 lands).
- **Concurrent:** C4-T02..T04 touch other regions of `config.ex`; serialize merges or
  rebase (same file). **Dependents:** C4-T05; MP-R7 (backend checks register here).

## Verified starting point (`45a290e3`)

```elixir
defp validate_semantics(settings) do                 # config.ex:1311
  with :ok <- validate_kinds_and_secrets(settings),
       :ok <- Schema.validate_turn_sandbox_policy(settings) do
    Aiur.Opencode.Config.validate!()
  end
end
defp validate_kinds_and_secrets(settings) do         # config.ex:1319
  cond do
    is_nil(settings.tracker.kind) -> {:error, :missing_tracker_kind}
    settings.tracker.kind not in ["linear", "github", "memory"] -> {:error, {:unsupported_tracker_kind, …}}
    settings.agent.kind not in Aiur.CodingAgent.dispatchable_backends(…) -> {:error, {:unsupported_agent_kind, …}}
    linear and no api_key -> {:error, :missing_linear_api_token}
    linear and no project_slug -> {:error, :missing_linear_project_slug}
    settings.tracker.kind == "github" -> Aiur.GitHub.Config.validate!()
    settings.agent.kind == "claude" -> Aiur.Claude.Config.validate!()
    true -> :ok
  end
end
```

- **Quirk to preserve:** because `cond` stops at the first true branch, with
  `tracker.kind: github` and `agent.kind: claude`, `Aiur.Claude.Config.validate!/0` is
  never called. This ticket keeps that behaviour (a refactor must not change it) and the
  PR files an issue asking whether it is intended.
- Public entry: `Aiur.Config.validate!/0` (`config.ex:1203-1208`). Tests that exercise
  it include `src/test/aiur/workspace_and_config_test.exs`, `core_test.exs`,
  `github/config_test.exs`, `opencode/config_test.exs`; error atoms
  `:missing_linear_api_token`/`:unsupported_agent_kind` are asserted in
  `orchestrator_status_test.exs` and `dynamic_tool_test.exs`.

## Chosen design

- Registry order reproduces the `cond` exactly:
  `exclusive: [Tracker.SemanticCheck.MissingKind, Tracker.SemanticCheck.UnsupportedKind,
  CodingAgent.SemanticCheck.Dispatchable, Tracker.SemanticCheck.LinearToken,
  Tracker.SemanticCheck.LinearSlug, GitHub.Config.SemanticCheck, Claude.Config.SemanticCheck]`;
  `always: [Config.Schema.TurnSandboxPolicyCheck, Opencode.Config.SemanticCheck]`.
  (One module may implement several checks via a `{module, :name}` tuple if preferred;
  record the choice.)
- `applies?/1` of each exclusive check is the `cond` condition; `check/1` is the branch
  body (for the error branches, `check/1` returns the error directly).
- Missing registry (misconfigured app env) → `{:error, :config_checks_unregistered}`,
  never `:ok` (fail closed).

## Implementation steps

1. Characterization test first (runs on unchanged code): a table of settings fixtures →
   expected `validate!` result, including the github+claude quirk.
2. Behaviour + evaluator in `config.ex` (or a new `config/semantic_checks.ex` to start the
   U8 split).
3. Check modules beside owners; registry in `config.exs`.
4. Delete the old private functions. Regenerate nothing: C1-T05 forces removal of the
   three allowlist lines.

## Non-happy paths

- A check raises → propagate exactly as today (today `validate!` functions may raise;
  no new rescue).
- Registry order typo → characterization table catches it.

## Compatibility and rollout

No config key, file format or error atom changes. Rollback: revert.

## Verification

PROPOSED `src/test/aiur/config/semantic_checks_test.exs` (characterization, written and
green **before** the refactor):

| Case | Expected |
|---|---|
| tracker kind nil | `{:error, :missing_tracker_kind}` |
| tracker kind "jira" | `{:error, {:unsupported_tracker_kind, "jira"}}` |
| agent kind not dispatchable | `{:error, {:unsupported_agent_kind, _}}` |
| linear without api key / slug | the two linear atoms |
| github tracker → GitHub check result | stubbed via the check module's injectable fun |
| **github tracker + claude agent → Claude check not called** | spy count 0 |
| memory tracker + claude → Claude check called | spy count 1 |
| sandbox policy error short-circuits Opencode check | Opencode spy 0 |
| empty registry | `{:error, :config_checks_unregistered}` |

Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/config/semantic_checks_test.exs test/aiur/workspace_and_config_test.exs test/aiur/core_test.exs test/aiur/github/config_test.exs test/aiur/opencode/config_test.exs`.

Mutation check: change the evaluator to run every applicable exclusive check → the
github+claude case fails; return `:ok` for an empty registry → last case fails.
Characterization rows (other than the two above) pass before and after by design; they
are regression guards, named as such in the test module doc.

Checker: `python3 scripts/check-components.py` reports the three `config → …` allowlist
entries as stale; delete them in the PR.

## Completion and handoff

- [ ] Three edges removed; allowlist lines deleted.
- [ ] Quirk preserved and an issue filed (link in PR body).
- [ ] `config.ex` line count lower than before (U8 owner informed).
- [ ] Docs: none (no key, flag or behaviour change).
- **Dependents:** C4-T05; MP-R7 backend checks.
