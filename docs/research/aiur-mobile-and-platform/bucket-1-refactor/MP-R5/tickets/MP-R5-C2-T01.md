---
ticket_id: MP-R5-C2-T01
feature_id: MP-R5
chunk_id: MP-R5-C2
bucket: 1-refactor
title: Voice owns its quota meter and supervision — Aiur.Voice.quota_snapshot/0 and Aiur.Voice.child_specs/0
status: blocked
blocked_by: [DESIGN-R5, MP-R5-C1-T01]
prior_units: [U8]
prior_boundaries: ["VOX #36", "WEB #34", "CLI #31 (composition root)"]
prior_features: [ui-09, integrations-51]
prior_findings: []
size_owner: "WEB (dashboard_live.ex 2,903 lines): edit must be net-neutral"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C2-T01 — Voice owns its quota meter and supervision

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C2.
- **User value:** none visible. The ElevenLabs credits row and its refresh are
  unchanged. Core stops naming `Aiur.ElevenLabs.Quota` in the composition root
  and the dashboard, so an absent provider means "no row, no child".
- **Deliverable:**
  - New `Aiur.Voice.Provider` callbacks: `child_specs/0` and
    `quota_snapshot/0`.
  - The matching `Aiur.Voice` facade functions.
  - `Aiur.ElevenLabs` implements them: its children are
    `[Aiur.ElevenLabs.Quota]`, and its snapshot is `Aiur.ElevenLabs.Quota.snapshot/0`.
  - `aiur.ex` splices `Aiur.Voice.child_specs()` where `Aiur.ElevenLabs.Quota`
    sits today.
  - `DashboardLive` calls `Aiur.Voice.quota_snapshot/0`.
- **Non-goals:**
  - config schema and `init` ownership (C2-T02, blocked on MP-R1);
  - any change to `RunSummaryStrip` rendering.

## Dependencies and blockers

- **Blocked by:** DESIGN-R5 and MP-R5-C1-T01.
- **Not blocked by MP-R1.** This ticket uses no registration mechanism: the
  composition root asks the voice facade for its children. Once MP-R1's
  component child-spec assembly exists (R1 promotion test criterion 2), it
  replaces the explicit splice.
- **May run concurrently with:** C1-T02, C1-T03, C1-T04, C4-*.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur.ex:352-355` supervises `Aiur.ElevenLabs.Quota` inside the list
  built by `child_specs/1` (`:244`). It sits between `Aiur.GitHub.BrokerTimeout`
  (`:351`) and `{Aiur.BuildOrder.TicketDetailCoordinator, …}` (`:356`). The
  comment there says: "Absent an API key it observes nothing at all".
- `Aiur.ElevenLabs.Quota.snapshot/1` (`quota.ex:80-85`) returns
  `@unconfigured` when the process is absent (`catch :exit`).
- `src/config/config.exs:38` sets `:elevenlabs_quota_refresh?` to false for
  tests.
- `src/lib/aiur_web/live/dashboard_live.ex`:
  - `alias Aiur.ElevenLabs.Quota, as: ElevenLabsQuota` (`:19`);
  - the tick is at `:77`, `:128`, `:184` and `:248-250`;
  - `elevenlabs_quota_snapshot/0` (`:2642`);
  - the default map is at `:887`.
- `RunSummaryStrip` hides the row when `state: :unconfigured`
  (`components/operator_control_center/run_summary_strip.ex:61,99,311-313`).
- No existing test asserts the ElevenLabs strip row: a grep for
  `elevenlabs_quota` or `Credits` under `src/test/aiur_web` finds none.

## Chosen design

```elixir
# Aiur.Voice.Provider (added callbacks)
@callback child_specs() :: [Supervisor.child_spec() | module() | {module(), term()}]
@callback quota_snapshot() :: map()     # today's Quota.snapshot() shape

# Aiur.Voice
def child_specs, do: (p = provider()) && p.child_specs() || []
def quota_snapshot, do: (p = provider()) && p.quota_snapshot() || @unconfigured_quota
#   @unconfigured_quota = %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
#   — the same literal as dashboard_live.ex:887 and run_summary_strip.ex:30
```

- In `aiur.ex`, keep the child **order**. Split the literal list at `:355` into
  `[... Aiur.GitHub.BrokerTimeout] ++ Aiur.Voice.child_specs() ++ [{Aiur.BuildOrder.TicketDetailCoordinator, …} ...]`.
  Move the comment to `Aiur.ElevenLabs.child_specs/0`.
- In `DashboardLive`, replace the alias with nothing, and make
  `elevenlabs_quota_snapshot/0` call `Aiur.Voice.quota_snapshot/0`. Keep the
  assign name `:elevenlabs_quota`; renaming it would touch the component API
  for no gain. The net line change in the file is ≤ 0.

## Implementation steps

1. Extend the `Aiur.Voice.Provider` behaviour and the facade. Implement both
   callbacks in `Aiur.ElevenLabs`.
2. Update the fake providers from C1 (test support) with `child_specs: []` and
   a fixed snapshot.
3. Edit `aiur.ex` and `dashboard_live.ex` as above.
4. Add the tests below.

## Non-happy paths

- **Provider nil:** no child is started, and the snapshot is
  `:unconfigured`, so the row is hidden. That matches the no-key presentation
  (DESIGN-R5 §2 "Units page credits row: hidden").
- **Quota process crashed:** unchanged. The `snapshot/1` catch gives
  `:unconfigured`, and the supervisor restarts it.
- **Boot order:** unchanged. A test asserts it (below).

## Compatibility and rollout

No config or wire change. Rollback means reverting the PR.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/voice_test.exs test/aiur_web/operator_control_center_components_test.exs test/aiur/eleven_labs/quota_test.exs \
  test/aiur/application_test.exs
```

New tests:

| Test | File | Expected |
| --- | --- | --- |
| "child specs come from the voice provider" | `test/aiur/voice_test.exs` | Default provider → `[Aiur.ElevenLabs.Quota]`; nil → `[]`. |
| "quota snapshot is unconfigured without a provider" | same | nil provider → exactly `%{state: :unconfigured, window: nil, failure: nil, observed_at: nil}`. |
| "the ElevenLabs credits row is absent when voice is not installed" | `operator_control_center_components_test.exs` | Render `RunSummaryStrip` with `elevenlabs_quota: Aiur.Voice.quota_snapshot()` under a nil provider; refute "Credits". Then with `%{state: :observed, window: %{used_percent: 10, reset_at: nil}}`, assert "Credits". |
| "the voice children keep their boot position" | `test/aiur/application_test.exs` (existing `AiurApp.child_specs/1` tests, `:150-169`) | `Aiur.ElevenLabs.Quota` sits immediately after `Aiur.GitHub.BrokerTimeout` in `Aiur.child_specs/1`. |

Mutation checks:

- Make `quota_snapshot/0`'s nil branch return `%{state: :unknown, …}`. The
  row test and the snapshot test fail. This is the plan's mutation.
- Make `child_specs/0` return `[Aiur.ElevenLabs.Quota]` regardless of the
  provider. The nil case fails.
- Move the splice after `Aiur.Events.IdGenerator`. The boot-position test
  fails.

## Completion and handoff

- [ ] `git grep -n "ElevenLabs" -- src/lib/aiur.ex src/lib/aiur_web/live/dashboard_live.ex`
  is empty.
- [ ] `dashboard_live.ex` line count is not larger than at the base.
- [ ] Docs: none (internal).
- **Dependents:** C3-T01; MP-R1-C8, whose component child-spec assembly
  absorbs `Aiur.Voice.child_specs/0`.
