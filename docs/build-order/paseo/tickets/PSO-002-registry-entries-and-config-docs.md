# PSO-002 — Registry entries `paseo-claude` and `paseo-codex` plus config docs

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — Two data entries in the backend registry, their config keys, and the docs the lint job enforces.

**Risk:** low

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**External gates:** none

**Requirements:** R5, R11, R13

**Decisions:** DEC-001, DEC-002, DEC-011, DEC-013, DEC-014

**Design evidence:** 00-design.md sections 2, 3, 5, 8; 01-spike-report.md sections 3, 8

**Researched at:** 8199f5373

**Suggested labels:** `complexity:2`, `model:claude`, `phase:1`, `build-lane:paseo-core`; never `agent:todo`

## Outcome

`Aiur.CodingAgent.backends/0` carries `paseo-claude` and `paseo-codex`. Both are hidden from dispatch, labels, and the init wizard until an operator sets `agent.backend_configs.paseo-claude.enabled: true` (or the codex twin). Once enabled, `model:paseo-claude` labels parse, `agent.priority` and `agent.routing` accept the backend, and `aiur-paseo` is the launch command. Usage, pricing, and provider meters see no new family.

## Context and evidence

The registry is the single source of backend identity (`src/lib/aiur/coding_agent/backend.ex` moduledoc; `src/lib/aiur/coding_agent.ex:80`). `deepseek` in `src/lib/aiur/open_ai_compat/registry.ex` is the precedent for a backend that is registered but off by default: `dispatch_enabled_by_default: false`, flipped by `agent.backend_configs.deepseek.enabled: true` through `dispatchable_backends/1` (`coding_agent.ex:340-348`).

`provider_families/0` (`coding_agent.ex:465`) is derived from `presentation` descriptors deduplicated by `family`, and the decomposition research recorded that this list is baked into four usage modules at compile time. Both new entries declare `family: "claude"` and `family: "codex"`, so the family list is unchanged and nothing in `usage/`, `provider_meters/`, or the price table recompiles for a new provider.

`Aiur.GitHub.Labels.model_labels/1` (`src/lib/aiur/github/labels.ex:99`) seeds `model:<backend>` labels from `CodingAgent.override_labels/1` for the backends `Aiur.Init.Resume.agents_from_config/1` (`src/lib/aiur/init/resume.ex:110`) finds in `agent.priority` and routing. A hidden backend therefore never gets a label; an enabled and listed one does.

The install and presence checks in `src/lib/aiur/init/agent_cli.ex` read `default_command` (`agent_executable/1`, line 205) and `install_hint` (line 104) from the registry. Giving the entries both keys makes `aiur init` name the fix when the sidecar is missing, with no wizard code change (PSO-013 adds the offer step).

## Scope

- Add two entries to `backends/0` in `src/lib/aiur/coding_agent.ex`, after `claude-repl`:

  | key | `paseo-claude` | `paseo-codex` |
  |---|---|---|
  | `adapter` | `Aiur.AppServer.GenericBackend` | same |
  | `transcript` | `Aiur.Claude.Transcript` | same (the sidecar emits Claude-shaped `item/created` for both providers, DEC-008) |
  | `family` | `"claude"` | `"codex"` |
  | `default_command` | `"aiur-paseo --provider claude"` | `"aiur-paseo --provider codex"` |
  | `install_hint` | `"install it with: npm install -g aiur-paseo"` | same |
  | `permission_mode` | `nil` (falls to `agent.claude.permission_mode`) | `"full-access"` |
  | `dispatch_enabled_by_default` | `false` | `false` |
  | `configurable` | `true` | `true` |
  | `init_order` | `5` | `6` |
  | `can_interrupt` | `true` | `true` |
  | `safe_checkpoints` | `[]` | `[]` |
  | `immediate_delivery` | `true` | `true` |
  | `control_application_confirmation` | `:confirmed` | `:confirmed` |
  | `remote_control` | `false` | `false` |
  | `remote_worker` | `false` | `false` |
  | `runtime_report` | `:headless_wrapper` | `:headless_wrapper` |
  | `resumable` | `true` | `true` |
  | `fallback_backend` | `"claude"` | `"codex"` |
  | `rate_limit_fallback_target` | `false` | `false` |
  | `model_aliases` | `:native` | `:native` |
  | `models` | copy of the `claude` entry's list | copy of the `codex` entry's list |
  | `model_catalog` | `&ModelCatalog.extract_claude/1` with `model_catalog_backend: "claude"` | codex equivalent |
  | `efforts` | `[]` | `[]` |
  | `skill_install` | same as family | same as family |
  | `presentation` | family presentation with `label: "Paseo (Claude)"`, `tool_gap: false` | `label: "Paseo (Codex)"`, `tool_gap: false` |
  | `run_telemetry` | family value | family value |

  Any key not listed copies the family entry. Write a comment above each entry naming DEC-002.
- Confirm `resolve_backend_spec/2` splits `model:paseo-claude-opus` into backend `paseo-claude` and variant `opus` (the hyphenated-backend rule that already handles `claude-repl`), and `model:paseo-codex-gpt-5.6-luna` into `paseo-codex` plus `gpt-5.6-luna`.
- Docs, enforced by `scripts/check-config-docs.py`: `KNOWN_MAP_SUBKEYS["agent.backend_configs"]` (line 46) already lists `<backend>.enabled`, `<backend>.command`, `<backend>.model`. Add `<backend>.permission_mode` there and document all four in `website/docs-app/reference/configuration.md` under `## agent` near the existing `agent.backend_configs` prose, with a `paseo-claude` example and the sentence that both Paseo backends are hidden until enabled.
- `.aiur/examples/config.example`: a commented block showing `agent.backend_configs.paseo-claude.enabled: true`, `agent.priority` including `paseo-claude`, and the `PASEO_PASSWORD` env note.
- `Aiur.GitHub.Labels.describe/1` (`labels.ex:126`) produces a sensible description for `model:paseo-claude` ("Paseo-owned Claude session") without a new clause if it already formats from the presentation label; add a clause only if the output is wrong.

## Non-goals

- The adapter module (PSO-001). Until PSO-001 lands, `adapter:` may reference `Aiur.AppServer.GenericBackend` only if the module exists; if this ticket merges first, point `adapter:` at `Aiur.Claude.CodingAgent` with a `# PSO-001 swaps this` comment and let PSO-001 flip it. Both orders are valid.
- Wizard offer step (PSO-013), guide page (PSO-008), surface indicator (PSO-003).
- Any `paseo:` top-level config section; DEC-014 forbids it.

## Existing owner and reuse target

Extend `src/lib/aiur/coding_agent.ex` `backends/0`; reuse `Aiur.OpenAICompat.Registry.presentation/6` shape for the presentation map. Docs page `website/docs-app/reference/configuration.md`, example `.aiur/examples/config.example`, lint `scripts/check-config-docs.py` with its self-test `scripts/test-check-config-docs.sh`.

## Contract and invariants

- `provider_families/0` returns the same list before and after this change.
- `dispatchable_backends(%{})` excludes both entries; `dispatchable_backends(%{"paseo-claude" => %{"enabled" => true}})` includes `paseo-claude` only.
- `override_labels/1` for a selection that includes `paseo-claude` yields `model:paseo-claude` plus one `model:paseo-claude-<variant>` per entry in `models`.
- `fallback_backend("paseo-claude") == "claude"`, `fallback_backend("paseo-codex") == "codex"`.
- `resumable?("paseo-claude")` is `true`; `remote_control?("paseo-claude")` is `false`.
- `configurable_backends/0` lists the entries after `claude`, `codex`, `kimi`, `openrouter` only when enabled.

### Requirements

- PSO-002-R1. Both entries exist with exactly the DEC-002 capability values.
- PSO-002-R2. Both are invisible to dispatch, labels, and init until `agent.backend_configs.<backend>.enabled: true`.
- PSO-002-R3. `provider_families/0` is unchanged.
- PSO-002-R4. `model:paseo-claude` and `model:paseo-codex-<variant>` parse to the right backend and variant.
- PSO-002-R5. `scripts/check-config-docs.py` passes with the new `permission_mode` subkey documented.
- PSO-002-R6. The example config shows how to enable the backend.

## Refreshable implementation notes

- Put the two maps in a private helper `paseo_entries/0` that derives them from the family entries (`Map.merge(family_entry, overrides)`) so a future family change propagates. Keep the override map literal and complete so a reader sees every value.
- `presentation` maps carry `order`, `label`, `slug`, and colours (see `Aiur.OpenAICompat.Registry.presentation/6`). Reuse the family's colours; only `label` and `slug` differ. If `provider_descriptors/0` dedupes by family first-seen order, the Paseo presentation is never the family card, which is the intent.
- Check `Aiur.CodingAgent.efforts/1` consumers accept `[]` (the headless `claude` entry already has no efforts).

### Key technical decisions

- KTD-1. Same family, new backend. The research's compile-time family bake is avoided entirely by not introducing a family.
- KTD-2. Hidden by default through the existing `dispatch_enabled_by_default` mechanism, not a new switch. `deepseek` proves the path.
- KTD-3. `transcript: Aiur.Claude.Transcript` for both, because the sidecar normalizes both providers to the Claude item shapes (DEC-008). Codex-native transcript parsing is not needed.
- KTD-4. `fallback_backend` to the plain family so an unreachable daemon costs one retry, not a stranded issue (DEC-013).

## Acceptance and verification

### Agent gate

- Tests in `src/test/aiur/coding_agent_test.exs` (or new `src/test/aiur/coding_agent/paseo_registry_test.exs`):
  1. `dispatchable_backends(%{})` excludes both Paseo backends.
  2. `dispatchable_backends(%{"paseo-claude" => %{"enabled" => true}})` includes `paseo-claude` and still excludes `paseo-codex`.
  3. `provider_families/0` equals the value from before the change (pin the list).
  4. `resolve_backend_spec("paseo-claude-opus")` returns `{"paseo-claude", "opus"}`; `"paseo-codex-gpt-5.6-luna"` returns `{"paseo-codex", "gpt-5.6-luna"}`; `backend_for/1` on an issue labelled `model:paseo-claude` returns `"paseo-claude"` when enabled and the default backend when not.
  5. `fallback_backend/1`, `resumable?/1`, `remote_control?/1`, `runtime_report/1` return the DEC-002 values.
  6. `configurable_backends/0` ordering with both enabled: family entries first, then `paseo-claude`, `paseo-codex`.
  7. `override_labels(["paseo-claude"])` includes `model:paseo-claude`.
- `python3 scripts/check-config-docs.py` and `scripts/test-check-config-docs.sh` pass.
- `make all` green.

### At-merge gate

- CI green on the exact head; docs lint job green.

### Human/manual evidence

- `scripts/aiurdev init` on a scratch repo with `aiur-paseo` absent from PATH prints the `install_hint` when `paseo-claude` is in `agent.priority` (after PSO-013 the wizard also offers it).

## Failure, security, migration, and accessibility cases

- A config that lists `paseo-claude` in `agent.priority` without enabling it fails validation with the existing message `backend "paseo-claude" is disabled; set agent.backend_configs.paseo-claude.enabled: true to opt in` (`src/lib/aiur/config/schema/agent.ex:379`). Assert this in a test.
- No secrets in the registry; the daemon password lives in the sidecar's env (DEC-014).
- No migration.

## Surfaces

- Reads: none new.
- Writes: `src/lib/aiur/coding_agent.ex`, `scripts/check-config-docs.py`, `website/docs-app/reference/configuration.md`, `.aiur/examples/config.example`, tests.
- Contracts: registry capability map (`Aiur.CodingAgent.Backend.capabilities/0`).

## Sibling boundaries and open gates

PSO-001 owns the adapter module the entries name. PSO-008 owns the guide page; this ticket touches only the configuration reference and the example. PSO-013 owns the wizard offer.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the approved planning commit linked in this issue's preamble):

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
