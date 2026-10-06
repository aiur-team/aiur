---
ticket_id: MP-R1-C2-T02
feature_id: MP-R1
chunk_id: MP-R1-C2
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: Aiur.Identity facade - instance_id from AIUR_INSTANCE_KEY, machine and instance sections
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C2-T01]
prior_units: []
prior_boundaries: ["CLI #31 (launcher identity)", "EXE #26 (claims consumer id)"]
prior_features: [MP-N2, MP-R2]
prior_findings: []
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C2-T02 — `Aiur.Identity` facade and `instance_id`

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C2. Contract §1.2.
- **User value:** one function every component calls for "which machine and instance am
  I", so event envelopes (MP-R2), Commands (MP-E2), conversations (MP-E4) and pushes
  (MP-N4) share one `instance_id = <machine_id>/<instance_key>` (RC-02).
- **Deliverable:** PROPOSED `src/lib/aiur/identity.ex` (`Aiur.Identity`, the component
  facade) with:

  ```elixir
  @spec machine() :: {:ok, %{machine_id: String.t(), label: String.t()}} | {:degraded, atom()}
  @spec instance_key() :: {:ok, String.t()} | {:error, :instance_key_missing | :instance_key_invalid}
  @spec instance_id() :: String.t() | nil
  @spec instance_section() :: %{instance_id: String.t() | nil, aiur_version: String.t(), run_shape: map()}
  @spec identity_capability() :: %{state: atom(), reason: atom() | nil}
  ```
- **RQ3 answer (no launcher change needed):** the launcher already exports
  `AIUR_INSTANCE_KEY` to the release (`aiur-engine.sh:291-298`), and the daemon already
  reads it (`config/paths.ex:331-335`, `executor/claims.ex:477-482`).
- **Non-goals:** repository and executor sections (providers in C3-T02), session identity
  (MP-E4 owns `SessionRef`, contract §1.5), changing `instance_key` derivation, the
  launcher record (MP-N2).

## Dependencies and blockers

- DESIGN-R1 §1 and S3; C2-T01.
- **Concurrent:** C3-T01 can be written against this signature in parallel.
- **Dependents:** C3-T01 (report assembly), C3-T02, MP-R2 envelope `instance_id`.

## Verified starting point (`45a290e3`)

- `aiur_instance_key` = first 10 hex of sha256(realpath(root)); empty only for an
  unreadable cwd (`aiur-engine.sh:263-278`). Pre-set values are honored, including an
  explicit empty value (`${AIUR_INSTANCE_KEY+x}`, `:291-293`).
- Existing consumers treat a missing key differently: `Config.Paths` fails closed
  (`{:error, :missing_instance_key}`, `paths.ex:331-335`); `Executor.Claims` falls back
  to `"default"` (`claims.ex:477-482`). This ticket does not change either.
- Version: `src/mix.exs:7` `version: "0.0.9"`; `Application.spec(:aiur, :vsn)` reads it
  at runtime.
- Run-shape flags are application env read in `start/2`: `:no_dashboard` (`aiur.ex:67`),
  `:headless` (`:71`), `:interactive_cli` (`:75`), `:executor_mode`
  (`aiur.ex:249`, `child_specs/1`).

## Chosen design

- `instance_key/0`: `System.get_env("AIUR_INSTANCE_KEY")`; `nil`/`""` →
  `:instance_key_missing`; not `~r/^[A-Za-z0-9_-]{1,64}$/` → `:instance_key_invalid`.
- `instance_id/0`: both `machine/0` ok and key ok → `"#{machine_id}/#{key}"`, else `nil`.
- `instance_section/0`: `aiur_version` from `Application.spec(:aiur, :vsn) |> to_string()`;
  `run_shape` from the four application env flags: `http_listener = not no_dashboard`,
  `dashboard_pages = http_listener` (MP-R1-C6-T03 later makes it independent),
  `dashboard` = `http_listener` (deprecated v1 alias, contract §2.2), `headless`,
  `interactive_cli`, `executor_mode`.
- `identity_capability/0` mapping:

  | Condition | state | reason |
  |---|---|---|
  | machine ok, key ok | `available` | — |
  | machine ok, key missing/invalid | `degraded` | `instance_key_missing` / `instance_key_invalid` |
  | machine degraded | `degraded` | `identity_unreadable` (both unreadable and uncreatable map here) |
  | `Machine.current/0` returns `:not_loaded` (boot step skipped) | `unknown` | `unknown` |

- Pure reads; no process. Layer L1: references only `Aiur.Identity.Machine` (own
  component) and `Application`/`System`.

## Implementation steps

1. Write `identity.ex` with the five functions and `@spec`s (`specs.check` requires them,
   CONTRIBUTING "Enforcement").
2. Tests with env injection: wrap `System.put_env`/`delete_env` in `on_exit`, `async: false`
   for env-mutating cases only.
3. Manifest: `identity` facades `["Aiur.Identity", "Aiur.Capabilities", "Aiur.Capabilities.Provider"]`.

## Non-happy paths

- Key present but machine degraded → `instance_id: nil`; clients must not fabricate one.
- Key changes while running: impossible (env read per call returns the launch value);
  documented as launcher-owned.
- `Application.spec` returns `nil` in an unusual test context → `aiur_version: "unknown"`.

## Compatibility and rollout

Additive; no caller changes in this ticket. Rollback: revert.

## Verification

PROPOSED `src/test/aiur/identity_test.exs`:

| Test | Expected |
|---|---|
| `instance_id joins machine id and key` | `"<26>/3f9a1c0b2e"` |
| `missing key gives nil instance_id and degraded identity` | `nil`; `%{state: :degraded, reason: :instance_key_missing}` |
| `invalid key (contains '/') is rejected` | `:instance_key_invalid` |
| `degraded machine gives nil instance_id even with a key` | `nil`; reason `identity_unreadable` |
| `run_shape reflects application env` | set `:no_dashboard` true → `http_listener: false`, `dashboard_pages: false`, `dashboard: false` |
| `not loaded is unknown, never available` | `Machine.current/0` stubbed `:not_loaded` → `:unknown` |

Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/identity_test.exs`.

Mutation check: return `"default"` instead of `nil` for a missing key → second test
fails; map `:not_loaded` to `available` → last test fails (AGENTS.md unknown-path
mutation rule).

## Completion and handoff

- [ ] Facade merged with specs; tests fail under both mutations.
- [ ] No docs change here (C3-T03 concepts page documents identity fields).
- **Dependents:** C3-T01, C3-T02, MP-R2-C5-T04 (envelope identity), MP-N2.
