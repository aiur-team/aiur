---
ticket_id: MP-R1-C3-T7
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: Optional-component capability providers - build orders, voice, Stream Deck, webhooks, Remote Control, accounting, conversations
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C3-T2]
prior_units: []
prior_boundaries: ["BO #30", "VOX #36", "SD #35", "ING #9", "CLD #22", "PM+USG #25", "PRJ #28"]
prior_features: [MP-R5, MP-R6, MP-E4, MP-N3, MP-N5]
prior_findings: []
size_owner: n/a (new provider files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T7 — Optional-component providers

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3.
  [capability-matrix.md §2–§5](../capability-matrix.md).
- **User value:** optional features say "off, and why" instead of looking broken or
  showing zeros: build-order progress absent (not 0%) without a root; mic hidden with
  "not configured"; Stream Deck explains a missing API (brief N3, AGENTS.md
  unknown/unavailable rendering).
- **Deliverable:** PROPOSED providers, each in its owning component directory and
  registered in config:

  | Provider | IDs |
  |---|---|
  | `Aiur.BuildOrder.CapabilityProvider` | `build_orders`, `build_orders.progress` |
  | `Aiur.ElevenLabs.CapabilityProvider` | `voice.stt`, `voice.tts` |
  | `AiurWeb.StreamdeckCapabilityProvider` (web-shell side of streamdeck-server) | `streamdeck` |
  | `Aiur.Webhooks.CapabilityProvider` | `webhook_ingress` |
  | `Aiur.Claude.RemoteControl.CapabilityProvider` | `remote_control` |
  | `Aiur.ProviderMeterProjection.CapabilityProvider` | `accounting.meters` |
  | `Aiur.LiveConversation.CapabilityProvider` | `conversations.read` |
- **Non-goals:** `conversations.anchors` (MP-E4/MP-R6), `voice.conversation` (MP-E6),
  `listener_modes` (MP-E7), `pairing`/`push` (MP-N2/N4), `build_queue` (MP-E1),
  `events.export` (MP-R2), `harness.*` (MP-R7). Those IDs stay in the known-ID table as
  `not_installed` until their features register providers.

## Dependencies and blockers

- DESIGN-R1 §1; C3-T2 (`api.http` semantics and the cross-ID rule).
- **Concurrent:** T3–T6. MP-R6-C1 may move `streamdeck_*` files; whichever merges second
  moves the provider with them.
- **Dependents:** MP-N3 (meta-dashboard), MP-N5 (progress notifications need
  `build_orders.progress`), MP-R5/R6 (adopt the report in their clients).

## Verified starting point (`45a290e3`)

- Build orders: `Aiur.BuildOrder.GraphProjection` child (`aiur.ex:357`, runtime config);
  `catalog/1` is a `GenServer.call` returning `Snapshot.t()` with `data`, `health`
  (`graph_projection.ex:43-44`, `graph_projection_contract.ex:17-38`). Build orders
  need GitHub GraphQL (capability-matrix §5); Linear → `unsupported_tracker`.
- Voice: `elevenlabs.api_key`, `elevenlabs.voice_id` (`config/schema/eleven_labs.ex:13,19`).
  Today's availability check `StreamdeckProjection.voice/0` treats an unreadable config
  as "not configured" (`streamdeck_projection.ex:34-55`); the provider must report
  `unknown` for that case instead (collapsed cause, AGENTS.md).
- Stream Deck: `POST /api/v1/streamdeck/token` requires dashboard credentials
  (`router.ex:180-184`, `:dashboard_auth_required`).
- Webhooks: `Aiur.Webhooks.ModeTable.put/2` stores the full `DeliveryMode` struct per
  repo; `transport/1` returns `:webhook | :polling` (`mode_table.ex:56-76`); states
  `:never_configured | :configured_unproven | :webhook_backed | :degraded`
  (`delivery_mode.ex:70`).
- Remote Control: `Aiur.Config.agent_remote_control?/0` (`config.ex:429-431`); routing
  `+remote`; needs the HTTP hook endpoint (AGENTS.md "Running").
- Accounting: `Aiur.ProviderMeterProjection.snapshot/1` (`provider_meter_projection.ex:72-73`, GenServer call).
- Conversations: `Aiur.LiveConversation` child (`aiur.ex:425`); history over
  `GET /api/v1/:issue_identifier/events` (`router.ex:191`).

## Chosen design

| ID | Rule (first match) |
|---|---|
| `build_orders` | `tracker.kind != "github"` → `unavailable/unsupported_tracker`; GraphProjection process nil → `unavailable/not_running`; `catalog` health not ok → `degraded/unknown` (carry `observed_at`); else `available` |
| `build_orders.progress` | `build_orders` not available → `unavailable/dependency_unavailable`; catalog has no root → `unavailable/not_configured`; else `available` |
| `voice.stt` | `api.http` not available → `unavailable/dependency_unavailable`; settings unreadable → `unknown/unknown`; key blank → `unavailable/not_configured`; else `available` |
| `voice.tts` | `voice.stt` not available → same as `voice.stt`; `voice_id` blank → `unavailable/not_configured`; else `available` |
| `streamdeck` | `api.http` not available → `dependency_unavailable`; dashboard credentials not configured → `unavailable/not_configured`; else `available` (sidecar presence is not knowable from the daemon) |
| `webhook_ingress` | no struct for the configured repo or `:never_configured` → `unavailable/not_configured`; `:configured_unproven` → `degraded/unknown`; `:degraded` → `degraded/not_running`; `:webhook_backed` → `available` |
| `remote_control` | not enabled in config or routing → `unavailable/disabled`; `api.http` not available → `unavailable/dependency_unavailable`; else `available` |
| `accounting.meters` | projection process nil → `unavailable/not_running`; no provider keys configured → `unavailable/not_configured`; else `available` |
| `conversations.read` | `api.http` not available → `dependency_unavailable`; LiveConversation nil → `degraded/not_running` (history on disk still served); else `available` |

Credentials are checked for presence only; values never leave the provider.

## Implementation steps

1. Seven provider modules with injected inputs; `ModeTable.mode/1` (PROPOSED, read-only
   `:ets.lookup`) added to return the stored struct.
2. Register in config; manifest entries per owning component.
3. Update the concepts page table (C3-T3) with the new IDs' meanings.

## Non-happy paths

- GraphProjection call slow (large catalog) → registry timeout → `unknown` (never
  `available`, never `not_configured`).
- Linear tracker → build orders `unsupported_tracker`, progress `dependency_unavailable`;
  N3/N5 render "absent", not 0 (acceptance 6).
- Unreadable config → `unknown` for config-derived IDs.

## Compatibility and rollout

Additive. Existing `StreamdeckProjection.voice/0` is untouched (MP-R5/R6 decide whether
to read the report instead). Rollback: remove providers from config or revert.

## Verification

PROPOSED `src/test/aiur/capabilities/optional_providers_test.exs`, one table-driven test
per rule row. Highlights:

| Test | Expected |
|---|---|
| `build_orders.progress: no root is unavailable, never zero` | `unavailable/not_configured`, no numeric field anywhere in the entry |
| `build_orders: linear is unsupported_tracker` | as stated |
| `voice.stt: unreadable settings is unknown, not not_configured` | `unknown/unknown` |
| `voice.stt: key removed flips only voice ids` | compare full report before/after: only `voice.*` differ (acceptance 5) |
| `webhook_ingress: configured_unproven is degraded` | `degraded/unknown` |
| `streamdeck: no dashboard credentials is not_configured` | as stated |
| `build_orders: slow catalog becomes unknown` | registry budget exceeded → `unknown` |

Command: `$TESTCMD test/aiur/capabilities/optional_providers_test.exs`.

Mutation check (unknown-path rule): replace the unreadable-settings branch with
`not_configured` → test 3 fails; return `available` with `percent: 0` for no root →
test 1 fails.

## Completion and handoff

- [ ] Providers registered; mutations fail the named tests.
- [ ] Concepts page rows added (docs ship with the change).
- **Dependents:** MP-N3, MP-N5, MP-R5, MP-R6.
