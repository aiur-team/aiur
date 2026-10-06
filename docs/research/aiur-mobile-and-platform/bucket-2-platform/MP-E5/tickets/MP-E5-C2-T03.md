---
ticket_id: MP-E5-C2-T03
feature_id: MP-E5
chunk_id: MP-E5-C2
bucket: 2-platform
title: Publish voice.stt and voice.tts capabilities and assign them at dashboard render time
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: data only; rendering is unchanged until the C6-T01 render ticket)", MP-R5-C1-T01, MP-R1-C3-T01]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07, integrations-51]
prior_findings: []
size_owner: WEB (dashboard_live.ex 2,903 lines — the change is net-neutral: one assign line; logic lives in a new module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C2-T03 — Voice capability callback and render-time availability

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C2.
- **User value:** clients (dashboard, phone, watch) can tell "voice is not configured" from
  "voice failed" before anyone presses a microphone (contract §7, client-capability-model
  rule 1 "detect, do not infer").
- **Deliverable:**
  1. `Aiur.Voice.Capability.capabilities/0` (PROPOSED, `src/lib/aiur/voice/capability.ex`)
     returning the `voice.stt` and `voice.tts` entries in the MP-R1 report shape, registered
     with the MP-R1 capability registry (`Aiur.Capabilities`, proposed by MP-R1-C3-T01).
  2. `DashboardLive` assigns `:voice_capabilities` at mount and on the existing 60 s quota
     tick, and passes it to `<.voice_input capabilities={…}>`, which renders it only as
     `data-voice-stt-state` / `data-voice-stt-reason` attributes (no visible change).
- **Non-goals:** changing what the user sees when voice is unavailable (E5-OQ4 → C6-T01);
  `voice.conversation` (MP-E6-C3).

## Dependencies and blockers

- **Predecessors:** MP-R5-C1-T01 (`Aiur.Voice.availability/0`), MP-R1-C3-T01 (capability
  registry and report shape; Phase D narrowed the earlier chunk reference `MP-R1-C2`, which is
  identity, not the registry). If MP-R1-C3-T01 has not landed, step 1's registration is skipped
  and the callback is called directly by `DashboardLive`; the report endpoint picks it up
  when the registry lands (plan refresh, `../plan.md` §10).
- **Contracts:** voice-session §7; identity-and-capabilities §2.2–§2.4.
- **May run concurrently with:** MP-E5-C2-T01/T02.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| No render-time voice availability | the dashboard learns "not configured" only from a failed join (`voice_channel.ex:253-254`; test `voice_channel_test.exs:156`) |
| Precedent | `StreamdeckProjection.voice/0` reports `%{available, reason}` (`streamdeck_projection.ex:34-56`, per MP-R5 plan §1.2) |
| Config readers | `Aiur.Config.elevenlabs_api_key/0`, `elevenlabs_voice_id/0` (`config.ex:329-340`) |
| Writable flag | `AiurWeb.Endpoint.config(:dashboard_writable)` (`voice_channel.ex:49`, `voice_socket.ex:23`) |
| Mount and tick | `DashboardLive.mount/3` assigns `:elevenlabs_quota` (`dashboard_live.ex:128`); quota refresh on a 60 s tick (`:248-250`, per MP-R5 plan §1.2) |
| Report shape | MP-R1 `{state, reason?, depends_on?}`, states `available | degraded | unavailable | unknown` (`contracts/identity-and-capabilities.md` §2.2) |

## Chosen design

```elixir
# Aiur.Voice.Capability (PROPOSED)
@spec capabilities() :: %{String.t() => map()}
def capabilities do
  writable? = AiurWeb.Endpoint.config(:dashboard_writable) == true   # injected as an arg in tests
  stt = Aiur.Voice.availability()                                      # MP-R5
  %{"voice.stt" => entry(stt, writable?), "voice.tts" => tts_entry(stt, voice_id_present?(), writable?)}
end

defp entry(%{available: true}, true),  do: %{state: "available"}
defp entry(%{available: true}, false), do: %{state: "unavailable", reason: "disabled"}
defp entry(%{reason: :unconfigured}, _), do: %{state: "unavailable", reason: "not_configured"}
defp entry(%{reason: :not_installed}, _), do: %{state: "unavailable", reason: "not_installed"}
defp entry(_other, _),                   do: %{state: "unknown", reason: "unknown"}
```

- `voice.tts` is `available` only when `voice.stt` is available **and**
  `elevenlabs.voice_id` is set; otherwise `unavailable/not_configured` (or the STT reason).
- The `:unconfigured` → `not_configured` spelling change happens only here (contract §7).
- The read-only dashboard is `disabled`, matching MP-R1's reason list.
- **Layering:** the module reads the endpoint flag through an injected function argument
  (`writable_fun`, default `fn -> AiurWeb.Endpoint.config(:dashboard_writable) == true end`)
  so the core voice code does not call `AiurWeb` directly at compile time; the
  composition root passes the function when it registers the callback (MP-R1 §2.4).

## Implementation steps

1. Add `src/lib/aiur/voice/capability.ex` with the function above.
2. Register it with `Aiur.Capabilities` from the voice component's child spec / registration
   hook defined by MP-R1-C3-T01.
3. In `DashboardLive.mount/3` add `assign(:voice_capabilities, Aiur.Voice.Capability.capabilities())`
   next to `:elevenlabs_quota` (`:128`); refresh it in the same tick handler.
4. `<.voice_input>` (MP-E5-C1-T01) gains `attr :capabilities, :map, default: %{}` and renders
   `data-voice-stt-state` and `data-voice-stt-reason` on its root element only.
5. Pass the assign from the drawer call site.

## Non-happy paths

- `Aiur.Voice.availability/0` raises (provider module half-loaded): rescue →
  `%{state: "unknown", reason: "unknown"}`, never `available` and never `not_configured`
  (collapsed-cause rule).
- Config reloaded with a new key: picked up at the next tick (≤ 60 s) and on the next mount;
  the join-time check still guards correctness.

## Compatibility and rollout

No config change. The report gains two IDs already listed in MP-R1's capability matrix
(`capability-matrix.md` §2 rows `voice.stt`, `voice.tts`). The DOM gains two data
attributes. Rollback: revert.

## Verification

| Test (`test/aiur/voice/capability_test.exs`, PROPOSED) | Expected |
| --- | --- |
| "no key reports voice.stt unavailable/not_configured" | facade stub `%{available: false, reason: :unconfigured}` → exact map |
| "an absent provider reports not_installed" | stub `:not_installed` → `not_installed` |
| "a read-only dashboard reports disabled even with a key" | `writable_fun` false → `unavailable/disabled` |
| "voice.tts needs a voice id" | key present, `voice_id` nil → `voice.tts` `unavailable/not_configured`, `voice.stt` `available` |
| "an unclassified facade failure is unknown, never not_configured" | stub raises → `unknown/unknown` |
| `dashboard_live` render test "voice_input carries the stt state attribute" | HTML has `data-voice-stt-state="unavailable"` and `data-voice-stt-reason="not_configured"` when the key is unset |

```bash
env -C src mise exec -- mix test test/aiur/voice/capability_test.exs test/aiur_web/operator_control_center/conversation_drawer_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Replace the `rescue` branch with `%{state: "unavailable", reason:
"not_configured"}`: the "unclassified … unknown" test fails. Replace the
`:not_installed` clause with the `:unconfigured` result: the "not_installed" test fails
(the AGENTS.md unknown-path rule).

## Completion and handoff

- [ ] Callback returns the four documented states; `DashboardLive` assigns it; no visible
      change.
- [ ] Docs: none yet. C6-T01 documents the unavailable presentation; MP-R1 documents the
      report endpoint.
- **Dependents:** MP-E5-C3-T01, MP-E5-C6-T01, MP-E6-C3 (`voice.conversation` depends on
  `voice.stt`), MP-N6-C4-T01, MP-N7.
