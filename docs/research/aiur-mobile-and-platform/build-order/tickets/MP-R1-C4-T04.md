---
ticket_id: MP-R1-C4-T04
feature_id: MP-R1
chunk_id: MP-R1-C4
bucket: 1-refactor
title: Environment and global-config startup edges - Dotenv parser down, credential checks registered, GlobalConfigStartup reassigned to github
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T02]
prior_units: []
prior_boundaries: ["CFG #2", "GHC #5", "GHD #8", "INI #37", "DEC #27"]
prior_features: []
prior_findings: []
size_owner: "src/lib/aiur/env.ex 492 lines — must not grow past 500"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C4-T04 — Env and global-config startup edges

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C4. Step S9.
- **User value:** none visible. Env validation (config component) stops depending on
  GitHub, Init and Commands; startup error text and precedence stay identical
  (AGENTS.md "Auth" precedence rules are untouched).
- **Deliverable:**

  | # | Edge at base | Change |
  |---|---|---|
  | V1 | `Aiur.Env → Aiur.Init.Dotenv` (`env.ex:39,480-488`, `Dotenv.parse/2`) | Move the pure parser (`init/dotenv.ex`, 60 lines) to PROPOSED `Aiur.Env.Dotenv` (config component); `Aiur.Init.Dotenv` keeps a `defdelegate parse/2` for init callers. |
  | V2 | `Aiur.Env → Aiur.SupervisorToken` (`env.ex:40,331-335`) | Registered env check: PROPOSED behaviour `Aiur.Env.StartupCheck` (`@callback errors(env :: map()) :: [String.t()]`), registry `config :aiur, :env_startup_checks, [Aiur.SupervisorToken.EnvCheck]`; `validate/1` appends their errors in registry order after `type_errors ++ group_errors` (exact order of `env.ex:69`). |
  | V3 | `Aiur.Env → Aiur.GitHub.Config` (`env.ex:38,95`, default `keyring_fun: &Config.keyring_token/0`) | Default comes from `Application.get_env(:aiur, :keyring_token_fun_module, Aiur.GitHub.Config)` → `mod.keyring_token/0`; callers that pass `:keyring_fun` are unchanged. The credential names list (`env.ex:168-171`) stays: it is env schema data, not GitHub code. |
  | V4 | `Aiur.GlobalConfigStartup → GitHub.Config, GitHub.Transport, GitHub.Labels, BuildOrder.Bounded` (`global_config_startup.ex:29,71,82-83`) | **Manifest reassignment, no code change:** the module ensures GitHub workflow labels for a global config, which is GitHub behaviour; it moves to component `github` (and its file to `src/lib/aiur/github/global_config_startup.ex` with module name unchanged, or path unchanged with ownership changed — record the choice). It is called only from the composition root (`aiur.ex:69`). The `Bounded` edge then becomes `github → kernel` after C5-T02. |

- `Aiur.WorkflowStore → Aiur.Alerts` (`workflow_store.ex:512`) is **not** here: it is an
  alert call and moves with the signal port migration (C5-T05).
- **Non-goals:** changing error messages, precedence, or `.env.example`
  (`scripts/check-env-example.py` must stay green).

## Dependencies and blockers

- DESIGN-R1 §1; C1-T02. Same-area serialization with C4-T01..T03 is not needed (different
  files), except `src/config/config.exs` (registry lines; trivial rebase).
- **Dependents:** C4-T05 (env ownership rule).

## Verified starting point (`45a290e3`)

- `Aiur.Env` aliases `Env.Schema`, `Env.Types`, `GitHub.Config`, `Init.Dotenv`,
  `SupervisorToken` (`env.ex:36-40`); `validate_startup!/2` signature and options at
  `env.ex:79-104`.
- `Aiur.GlobalConfigStartup.prepare/0` is the first step of the boot `with` in
  `Aiur.Application.start/2` (`aiur.ex:69`).
- CI guard `python3 scripts/check-env-example.py` (lint job) checks `.env.example`
  against the env schema; unaffected because `Aiur.Env.Schema` does not move.

## Chosen design

Same pattern as C4-T01: behaviour + ordered registry in `config.exs`; missing registry →
empty list (the supervisor-token check is additive; today an invalid token aborts
startup, so a missing registry would weaken that — therefore the default registry is
compiled into `Aiur.Env` as the fallback value of `Application.get_env/3`, so the check
cannot be lost by a missing config line).

## Implementation steps

1. Characterization tests (unchanged code): invalid supervisor token message; dotenv
   parse table (quotes, `export`, comments); keyring default used when no `:keyring_fun`.
2. V1–V3 code moves; V4 manifest change (and optional file move).
3. Delete stale allowlist lines; confirm `check-env-example.py` passes.

## Non-happy paths

- Registry overridden in a test env → only affects that test.
- Dotenv parser move must keep `Map.put_new` first-wins semantics in `read_dotenv/1`
  (`env.ex:480-488`) — unchanged code, only the parser moves.

## Compatibility and rollout

No behaviour, message or file-format change. Rollback: revert.

## Verification

Existing (verified at base): `test/aiur/env_test.exs` (exercises `validate_startup!`),
`test/aiur/init/dotenv_test.exs`, `test/aiur/application_test.exs`.
New:

| Test | Expected |
|---|---|
| `invalid supervisor token is reported through the registered check` | same message as `env.ex:333` |
| `default registry applies when app env is unset` | `Application.delete_env` → error still reported |
| `Init.Dotenv.parse delegates to Env.Dotenv.parse` | identical output for a fixture file |
| `keyring default comes from configured module` | stub module returns token → no credential error |

Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/env_test.exs test/aiur/init/dotenv_test.exs test/aiur/application_test.exs`.

Mutation check: drop the compiled-in fallback → `default registry applies...` fails;
reorder errors → the characterization message-order test fails.

## Completion and handoff

- [ ] V1–V3 edges removed, V4 reassigned; allowlist pruned.
- [ ] `check-env-example.py` green.
- [ ] Docs: none (no operator-visible change).
- **Dependents:** C4-T05.
