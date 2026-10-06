---
ticket_id: MP-R1-C7-T02
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Register tracker adapters instead of naming them in a case
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C7-T01, MP-R1-C4-T01]
prior_units: [U5, U7]
prior_boundaries: [TRK, CFG, GHD, LIN]
prior_features: [integrations-03]
prior_findings: [codebase-10]
size_owner: CONFIG (src/lib/aiur/config.ex, ledger row `src/lib/aiur/config.ex,1462,CONFIG,Configuration,split,medium` at 465aca643; 1,471 lines at 45a290e3); TEST_HARNESS owns core_test.exs and extensions_test.exs. Re-resolve at ticket start against the then-current U8 ledger (RC-23, MP-R1-C11-T02)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T02 — Register tracker adapters instead of naming them in a case

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (migration step S5; prior §7
  step 3 "replace the `case` lookups").
- **User value:** none visible. The `tracker` component stops naming the GitHub and
  Linear adapters, which removes the `TRK → GHD` and `TRK → LIN` edges
  (`feature-boundaries.md` §3.2 last row) and lets `github` and `linear` be optional
  components that attach at the composition root (rule R-optional, `component-map.md` §2).
- **Deliverable:** an adapter registry read from application config, used by
  `Aiur.Tracker.adapter/0`, `Aiur.CodeHost.adapter/0` (from C7-T01) and the tracker-kind
  validation in `Aiur.Config`.
- **Non-goals:** the other `"github" ->` branches outside these three sites
  (`events_digest.ex:73,227`, `comment_polling.ex:238,273`, `ci_lifecycle.ex:39`,
  `tracker_health.ex:368`, `workspace/layout.ex:107`, `init/questions.ex:57`,
  `init/resume.ex:83`) — they are recorded in the ratchet allowlist and removed by the
  tickets that own those files (C7-T05 for `layout.ex`, C9 for orchestrator files; init
  stays as is, it is setup UX). Coding-agent backend registration (MP-R7). Changing
  error atoms.

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** C7-T01 (CodeHost facade exists); MP-R1-C4-T01 (config registration
  mechanism) — this ticket uses the same "list of modules in app env" pattern so C4 and
  C7 do not invent two registries. If C4-T01 picks a different mechanism, this ticket
  follows it.
- **RC-19:** does not touch `github/labels.ex`, `github/issues.ex`, `issue_sync.ex` or
  `dispatch_policy.ex`; MP-E1-C1 hooks are unaffected. The queue's
  `Aiur.Tracker.add_label/2` path keeps resolving through `adapter/0`.
- **Concurrent with:** C7-T03, C7-T04, C7-T06. Serialize with C7-T01 (same file) and with any
  C4 ticket editing `config.ex` `validate_kinds_and_secrets/1`.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/tracker.ex:161-168`: `adapter/0` is
  `case Config.settings!().tracker.kind do "github" -> Aiur.GitHub.Tracker; "memory" -> Aiur.Memory.Tracker; _ -> Aiur.Linear.Tracker end`.
  The `_` fallback means any unknown kind resolves to Linear.
- `src/lib/aiur/config.ex:1311-1316` `validate_semantics/1` calls
  `validate_kinds_and_secrets/1` (`:1318-1345`), which hard-codes
  `["linear", "github", "memory"]` (`:1324`), Linear's two required keys (`:1330-1334`,
  error atoms `:missing_linear_api_token`, `:missing_linear_project_slug`) and
  `Aiur.GitHub.Config.validate!()` (`:1336-1337`).
- `Aiur.TrackerConfig` behaviour (`tracker_config.ex:1-7`, one callback `validate!/0`)
  is implemented by `github/config.ex:6,570`, `linear/config.ex`, `memory/config.ex`;
  only GitHub's is called by `Config`.
- Precedent for module registration through app env:
  `src/config/config.exs:24` (`:build_order_data_source`), read with
  `Application.get_env/3` at `build_orders_cli.ex:43` and `build_order_live.ex:44`.
- Tests: `src/test/aiur/core_test.exs:164`
  (`{:error, {:unsupported_tracker_kind, "123"}}`), `extensions_test.exs:365,399`
  (`Aiur.Tracker.adapter()` returns `Memory` / `LinearTracker`).
- Size: `src/lib/aiur/config.ex` is 1,471 lines at base and is owned by U8 package
  `CONFIG` (`assignments.csv:65`, 1,462 lines at `465aca643`). This ticket adds no
  lines to it net; re-check the owner at ticket start (RC-23).

## Chosen design

Registration is **compile-time application config at the composition root**, not a
runtime GenServer: the adapter set is fixed per build, it must be readable before any
process starts (config validation runs at boot), and app env is the existing pattern.

```elixir
# src/config/config.exs (composition root; outside src/lib, so not a component edge)
config :aiur, :tracker_adapters, %{
  "github" => Aiur.GitHub.Tracker,
  "memory" => Aiur.Memory.Tracker,
  "linear" => Aiur.Linear.Tracker
}
config :aiur, :tracker_fallback_kind, "linear"   # preserves tracker.ex:166
```

```elixir
# PROPOSED src/lib/aiur/tracker/registry.ex
defmodule Aiur.Tracker.Registry do
  @spec kinds() :: [String.t()]                  # sorted keys
  @spec adapter_for(String.t() | nil) :: module() # unknown/nil -> fallback kind's adapter
  @spec config_module(String.t()) :: module() | nil
end
```

Each adapter gains two optional callbacks on `Aiur.Tracker.IssueTracker`:

- `config_module/0 :: module()` — its `Aiur.TrackerConfig` implementation.
- `code_host/0 :: module() | nil` — GitHub returns `Aiur.GitHub.Tracker`; Linear and
  memory do not implement it, so `Aiur.CodeHost.adapter/0` returns
  `Aiur.Tracker.NullCodeHost` (same truth table as C7-T01).

`Config.validate_kinds_and_secrets/1` becomes:

1. `kind not in Registry.kinds()` → `{:error, {:unsupported_tracker_kind, kind}}` (same atom).
2. Agent kind check (`:1327-1328`), unchanged and in the same position.
3. `Registry.config_module(kind).validate_settings(settings)` — a new optional
   `TrackerConfig` callback returning either a final result or `:continue`:
   - Linear: its two checks (`:1330-1334`) with the **same** error atoms, else `:continue`.
   - GitHub: returns `GitHub.Config.validate!()` as a **final** result. At base the
     `cond` ends at `:1336-1337` for a GitHub tracker, so the Claude check at
     `:1339-1340` never runs for GitHub; this must be preserved.
   - memory: `:continue`.
4. On `:continue`, the Claude branch (`:1339-1340`) then `:ok`, as today.

Order check against the base `cond` (`config.ex:1320-1344`, top to bottom): nil kind,
unsupported kind, agent kind, Linear key, Linear slug, GitHub validate (terminal),
Claude validate, `:ok`. The new code reproduces it exactly. The agent-kind and Claude
checks stay in `Config` (owned by harness adapters, MP-R7).

**Invariant:** for every `(tracker.kind, settings)` input, `Config.validate!/0` returns
the same value as at base, and `Tracker.adapter/0` returns the same module.

## Implementation steps

1. Add `config :aiur, :tracker_adapters` and `:tracker_fallback_kind` to
   `src/config/config.exs` (all envs).
2. Add `Aiur.Tracker.Registry`; reading uses `Application.fetch_env!/2` so a release
   built without the key fails at boot with a clear `ArgumentError` rather than
   silently selecting nothing.
3. `tracker.ex:161-168`: `adapter/0` → `Registry.adapter_for(Config.settings!().tracker.kind)`.
4. `code_host.ex` (C7-T01): `adapter/0` → the tracker adapter's `code_host/0` if exported,
   else `NullCodeHost`.
5. Add `validate_settings/1` to `Aiur.TrackerConfig` as an optional callback; implement
   in `linear/config.ex`, `github/config.ex`, `memory/config.ex`.
6. Rewrite `config.ex:1318-1345` per the ordered design above.
7. Manifest: `tracker` component loses its `requires` on `github`/`linear`; those
   components declare `tracker` as required and register themselves. Regenerate the
   allowlist (two edges removed).

Estimated production change: ~120 lines.

## Non-happy paths

- **Unknown kind:** still rejected by validation with the same atom; if code reaches
  `adapter/0` with an unknown kind (as in tests that bypass validation), it still gets
  the Linear adapter via the fallback key — preserved deliberately, documented in
  `Registry` moduledoc.
- **Missing registry key in a custom release:** boot fails loudly (`fetch_env!`). This is
  a new failure mode only for builds that edit `config.exs`; in-tree builds always set it.
- **Optional component absent later:** when a future build drops `linear` from the map,
  `tracker.kind: linear` fails validation with `{:unsupported_tracker_kind, "linear"}` —
  correct "capability unavailable" behaviour, not a crash. MP-R1-C3 reports this as
  `unavailable: not_installed` for the tracker capability.
- **Test isolation:** tests that override `:tracker_adapters` must restore it
  (`on_exit`), because app env is global; prefer passing kind via config fixtures.

## Compatibility and rollout

- `.aiur/config` unchanged; error atoms unchanged; no migration.
- Rollback: revert (config and code in one PR).

## Verification

```bash
env -C src mise exec -- mix test test/aiur/core_test.exs test/aiur/extensions_test.exs \
  test/aiur/tracker_github_test.exs test/aiur/tracker/registry_test.exs
make -C src fmt-check && make -C src lint
python3 scripts/check-config-docs.py     # unchanged keys; must still pass
python3 scripts/check-components.py      # MP-R1-C1 (PROPOSED)
```

New tests (`src/test/aiur/tracker/registry_test.exs`):

1. "unknown kind resolves to the fallback adapter" — `adapter_for("123") == Aiur.Linear.Tracker`.
   **Mutation:** remove the fallback (return `nil`); fails.
2. "registered kinds are exactly github, linear, memory" — guards the map. **Mutation:**
   drop `"memory"` from `config.exs`; fails.
3. "validation error precedence is unchanged" — table test over five inputs: kind nil →
   `:missing_tracker_kind`; kind "123" → `{:unsupported_tracker_kind, "123"}`; kind linear
   with bad agent kind → `{:unsupported_agent_kind, _}`; linear with valid agent and no
   api key → `:missing_linear_api_token`; linear with key, no slug →
   `:missing_linear_project_slug`; plus kind github with `agent.kind: claude` and an
   invalid Claude config → GitHub's result, not Claude's error. **Mutation (a):** move the
   tracker settings validation ahead of the agent-kind check; case 3 fails.
   **Mutation (b):** make GitHub return `:continue` after a successful validate; the
   GitHub+Claude case fails.
4. Existing `core_test.exs:164` and `extensions_test.exs:365` stay green unchanged.

Manual: `scripts/aiurdev --test` boots with the GitHub tracker config; `aiurdev status`
reports normally.

## Completion and handoff

- [ ] `git grep -n 'Aiur.GitHub.Tracker\|Aiur.Linear.Tracker' -- src/lib/aiur/tracker.ex src/lib/aiur/code_host.ex src/lib/aiur/config.ex` is empty.
- [ ] Validation table test passes and fails under its mutation (PR body).
- [ ] Allowlist count lower by the removed `TRK → GHD/LIN` and `CFG → GHD` edges.
- **Docs:** none (no key or flag changes).
- **Dependents:** MP-R1-C3-T02 (capability callbacks can read `Registry.kinds()` for the
  tracker capability), C7-T06 (github component registers), MP-R7 (backend registration
  should reuse this pattern).
