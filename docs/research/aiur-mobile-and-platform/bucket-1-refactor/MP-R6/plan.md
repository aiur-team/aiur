---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-R6
bucket: 1-refactor
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: ../../owner-design-tasks/DESIGN-R6.md
blockers:
  - Conversation-anchor contract (owned by the MP-E4 planner) must accept §5 before C1 fixes the neutral module's API
  - MP-R1 package placement decides where the neutral modules live (C1 can land in-process first)
---

# MP-R6 — Stream Deck: separate shared projections from hardware presentation

## Summary

The physical integration **is already a separate package**: `packages/streamdeck`,
the `@aiur/streamdeck` sidecar. The dashboard already uses the daemon-side
projections without hardware, through the `/streamdeck` browser emulator.

MP-R6 is therefore small. It fixes the two places where shared data is still
bound to the deck:

1. **The event-to-transcript anchoring** (the most reusable "conversation
   anchor" in the codebase) is inside `AiurWeb.StreamdeckLogs`, mixed with
   deck paging, a pinned LIVE key and an eight-key window. C1 extracts the
   anchoring into a device-neutral module. `StreamdeckLogs` keeps the deck
   presentation.
2. **Core compilation reads a file inside the deck package.**
   `AiurWeb.StreamdeckKeyFaceContract` does
   `File.read!("packages/streamdeck/src/key-face-contract.json")` at compile
   time, and `StreamdeckLogs` uses it for the badge vocabulary. The dashboard
   cannot build without the deck package's source tree. C2 inverts that
   ownership.

The other projections (`StreamdeckProjection`, `StreamdeckCommands`,
`StreamDeckGrid`) are already hardware-free. C3 records that classification
and touches only the voice delegation shared with MP-R5.

Hold-to-dictate and focused-agent targeting are not modified. Acceptance
re-proves them.

Prior-units: U7, U8. Prior-boundaries: `SD` #35 ("sidecar repo candidate,
server side with web"), `WEB` #34, `PRJ` #28. Prior-features: `ui-15` (logs
projection), `ui-16` (keep the sidecar in the monorepo until a versioned
protocol exists). `ui-19` (demo mode) stays cut. Size-owner: `DECK_WEB` for
`streamdeck_logs.ex` (637 lines), `streamdeck_channel.ex` (609),
`streamdeck_projection.ex` (540) and `live/streamdeck_live.ex` (1,799);
`DECK_PKG` for `controller.ts` (1,102). C1 *reduces* `streamdeck_logs.ex`.

## 1. Repository findings (verified at `45a290e3`)

This extends `baseline/capability-baseline.md` § R6.

### 1.1 The anchoring algorithm (`src/lib/aiur_web/streamdeck_logs.ex`)

- **Inputs:** `load/1` (`:628-636`) reads `AgentEventFeed.bus_events/1` and
  `AgentEventFeed.list(identifier, %{"limit" => 50})`.
  - Bus history defaults to **40** rows (`agent_event_feed.ex:42`, `:107-114`).
  - The transcript is capped at **50**.
  - **Anchors are therefore computed over a bounded recent window, not a full
    transcript.**
- **Event identity:** `{:bus, kind, id}` (`:267-281`). The kind is part of the
  identity because a ticket can see its own event as both `emit` and
  `consumed`. That is a real duplicate-identity rule worth keeping.
- **Origin:** a synthetic `:origin` event at the earliest timestamp of either
  feed (`:287-305`).
- **Attach rule:** each transcript entry belongs to the **last event at or
  before its timestamp** (`assign_entries/2`, `:309-320`).
  - An event with a nil timestamp claims nothing.
  - Unattributable entries fall to the origin (`:322-332`).
  - Timestamps are compared as parsed `DateTime`s, and lexically only when
    unparseable (`:330-351`).
- **Presentation mixed into the same module:**
  - `@events_per_page 7` and the pinned LIVE key (`:55`, `:398-412`);
  - `@transcript_window_size 2` (emulator readout, `:59`);
  - `scroll/3`, `select_event/2`, `ensure_visible/1`, `visible/1`;
  - `line/1` text formatting (`:249-261`);
  - `wire/1`, the channel DTO (`:116-135`).
- **Anchor position:** each key carries `start`, a **row index into the
  flattened transcript window** (`:355-396`). That index is not stable across
  refreshes or a larger limit.
- **Hardware coupling:** `@directions Map.keys(AiurWeb.StreamdeckKeyFaceContract.direction_badges())`
  (`:64`). It is the only dependency on the visual contract, and it is used
  only for the badge **vocabulary**:
  `EMIT CONSUME AGENT SYSTEM INFO` (`streamdeck_key_face_contract.ex:14`).

### 1.2 Who uses what (census)

Command: `git grep -n -E "Streamdeck(Logs|Projection|Commands|…)|StreamDeckGrid" 45a290e3 -- src/lib`.

| Module | Hardware-free? | Consumers outside the deck channel |
| --- | --- | --- |
| `StreamdeckLogs` | Yes (apart from the badge vocabulary) | `StreamdeckLive` only (`live/streamdeck_live.ex:112,181,312,500,1415-1466`). `DashboardLive` does not use it. |
| `StreamdeckProjection` (`snapshot/0`, `voice/0`, `fleet/0`, `grid/0`, `provider_meters/*`, `decisions/0`, `transcript/2`, `alert/2`, `control/2`) | Yes | `StreamdeckLive` (`:768-806`) |
| `StreamdeckCommands` (`history/3`, `detail/2`, `item/1`, `actor/0` = `%{kind: :operator, id: "streamdeck"}`) | Yes; the `actor` id names the surface | `StreamdeckLive` (`:1455`) |
| `StreamDeckGrid` (`payload/2`, `project/2`, `dependency_ready?/2`) | Yes; ranks by `bucket_rank!` from the visual contract (`stream_deck_grid.ex:13,50,156`) | `ObservabilityApiController.streamdeck_grid` (`GET /api/v1/streamdeck/grid`, `observability_api_controller.ex:23`); a comment in `orchestrator/status_report.ex:1452` |
| `StreamdeckTranscriptRelay` (throttled live push) | Yes | `StreamdeckLive` (`:1761`) |
| `StreamdeckStrip` | **No**: touch-strip rendering hints | `StreamdeckLive` |
| `StreamdeckKeyFaceContract` | **No**: the visual contract | `StreamdeckLive`, `StreamDeckGrid`, `StreamdeckStrip`, `StreamdeckLogs` |
| `StreamdeckAuth` / `Socket` / `Channel` | Transport for the deck | the deck sidecar |

### 1.3 Visual contract ownership

- Canonical file: `packages/streamdeck/src/key-face-contract.json`.
- Consumers:
  - the sidecar (`key-face-contract.ts`, `keys.ts`, `logs.ts`, `rasterizer.ts`,
    `art/segments.ts`);
  - core, at compile time (`streamdeck_key_face_contract.ex:10-12`, with
    `@external_resource`).
- Agreement tests: `packages/streamdeck/test/key-face-contract.test.ts` and
  `src/test/aiur_web/streamdeck_key_face_contract_test.exs`.
- **Dependency direction today: core → deck package source.** For `SD` #35
  ("repo candidate once `key-face-contract.json` and `streamdeck:fleet` are
  the contract"), the protocol owner must be the daemon, and the sidecar must
  consume it.

### 1.4 Behaviour to preserve

- **Hold-to-dictate:**
  - Mic key-down calls `holdMic()` and key-up calls `releaseMic()`
    (`packages/streamdeck/src/controller.ts:781-790`, `:905-907`) in the
    `cmd`, `settings` and `commands` modes.
  - Text accumulates across holds. Send calls `sendTranscript(identifier)`
    (`:743`), which sends `say`.
  - Daemon side: `voice_start`, `voice_audio` and `voice_stop` with a
    session-id stale-frame guard (`streamdeck_channel.ex:193-230`). `say`
    goes to `AgentChat.send` (`:176-187`, `:468`).
- **Targeting:**
  - `focus` (`streamdeck_channel.ex:45-58`) sets the focused identifier.
  - `answer_command` passes `validate_focused_command/4` (`:159`, `:535`),
    with actor `StreamdeckCommands.actor/0`.
  - The Executor is never a target.
- **Tests:**
  - `packages/streamdeck/test/**` (controller, voiceHost, voicePanel, channel,
    logs, commands);
  - `src/test/aiur_web/streamdeck_{channel,commands,logs,projection,strip,voice_latency,key_face_contract,control_agreement}_test.exs`;
  - `stream_deck_grid_test.exs`;
  - `live/streamdeck_live_test.exs`.

## 2. Proposed boundary

| Layer | Contents | Package (after R1) | Depends on |
| --- | --- | --- | --- |
| **Conversation anchors (neutral)** | NEW `Aiur.Conversation.EventAnchors`. The name is provisional and is the MP-E4 contract's choice. It holds the origin synthesis, event identity, attach rule and timestamp parsing, as a pure function `anchor(events, transcript) :: [%{event, entries}]` plus `load(identifier, limits)`. | core or `aiur_projections` (`PRJ` #28) | `Aiur.AgentEventFeed` |
| **Event badge vocabulary (neutral)** | `EMIT CONSUME AGENT SYSTEM INFO` defined in the neutral module; the visual contract asserts agreement with it | same | none |
| **Shared fleet and command projections** | `StreamdeckProjection`, `StreamdeckCommands`, `StreamDeckGrid`, `StreamdeckTranscriptRelay`. **Kept in place and kept their names** (C3 rationale). | `aiur_web` (`SD` server side "with web") | Orchestrator, DecisionStore, `Aiur.Voice` (R5) |
| **Deck presentation (daemon side)** | `StreamdeckLogs` (paging, LIVE, window, `line/1`, `wire/1`, now delegating anchoring), `StreamdeckStrip`, `StreamdeckKeyFaceContract`, `StreamdeckLive` | `aiur_web` | neutral anchors; visual contract |
| **Deck protocol** | `streamdeck:fleet` channel events (`docs/streamdeck-channel.md`) plus the visual contract JSON, **owned by the daemon** | `aiur_web` | — |
| **Hardware** | `packages/streamdeck/**`: USB/HID, rasterizer, keys, touch strip, audio capture, controller | separate package (unchanged) | the deck protocol only |

The dashboard needs no deck package. Without one it gets:

- the neutral anchors (E4);
- the shared projections;
- the emulator (already the case).

## 3. Alternatives

| Option | Verdict |
| --- | --- |
| A. Rename every `Streamdeck*` daemon module to a neutral name | Rejected. It is churn across 4 files over 500 lines, and the Commands, Projection and Grid projections are deck-shaped DTOs. E2, N3 and N6 will read `DecisionStore` and the orchestrator snapshot directly, not the deck DTOs. Rename only what has a planned non-deck consumer. |
| B. Make E4 call `StreamdeckLogs.load/1` and ignore the paging fields | Rejected. It ties conversations to a 7-key page, a 50-row cap and the deck's badge contract, and E4 needs the full transcript. |
| C. Move the key-face JSON into `packages/aiur-style` | Possible, but `aiur-style` is the marketing and site design system (`package.json` description), not the deck protocol. Phase C RQ2 decides. |
| **D. Extract only the anchoring; invert visual-contract ownership; classify the rest** | **Recommended.** It is the smallest change that meets both brief requirements. |

## 4. Contracts

- **Owns:** none. The deck channel protocol is existing and unchanged.
- **Consumes:**
  - **Conversation anchors (MP-E4).** § 5.
  - **Voice availability (MP-R5).** `StreamdeckProjection.voice/0` delegates to
    `Aiur.Voice.availability/0` and keeps its wire shape (R5-C1-T04).
  - **Events and replay (MP-R2).** The bus event identity used for anchors
    (`id`, `kind`, `timestamp`) comes from `IssueLog.event_history`. If MP-R2
    changes event identity or adds sequence numbers, the anchor rule should
    prefer sequence over timestamp. The R2 owner must say whether a
    per-ticket monotonic sequence is available.

## 5. What the conversation-anchor contract (MP-E4 owner) needs from R6

The coordinator reconciles these:

1. **The attach rule as specified today:** last event at or before the
   entry's timestamp; a nil-timestamp event claims nothing; leftovers go to a
   synthetic origin. E4 may extend the rule, but the deck must keep producing
   the same groups. That is the C1 acceptance oracle.
2. **The identity tuple `{source, kind, id}`.** `kind` is needed to keep
   `emit` and `consumed` twins distinct.
3. **Stable anchor positions.** The deck's `start` is a row index into a
   capped, flattened window, which is fine for a deck and wrong for a
   reviewable transcript. The contract should anchor to a **transcript entry
   identity** (an entry id or sequence from `AgentEventFeed`), and let
   presentations derive row indices. Phase C RQ1 checks whether
   `AgentEventFeed.list/2` entries carry a stable id.
4. **Bounded versus full windows.** The neutral `load/2` takes explicit limits.
   The deck passes `bus: 40, transcript: 50` (today's values). E4 passes its
   own pagination. Origin semantics must be defined for a paginated window:
   is the "origin" the true ticket start or the window start?
5. **Missing kinds.** Today's bus kinds are progress, phase, comment, CI, PR,
   decision and attention. There are **no commit anchors** and **no
   Command-to-transcript link** (baseline E4). Those are E4 additions, not R6.
6. **Executor conversations** are out of R6. The anchors are per ticket
   identifier today.

## 6. Non-happy paths

| Case | Behaviour (must be unchanged) |
| --- | --- |
| Ticket with no bus events | Origin only; the transcript still renders (`agent_event_feed.ex:100-104` doc). |
| Unreadable transcript | `load/1` falls back to `[]` (`:631-633`). |
| Clock skew or unparseable timestamps | Lexical fallback; a nil event timestamp claims nothing. |
| Deck package absent | The daemon builds and serves the dashboard and emulator (after C2). The `/streamdeck` socket stays mounted. Without a sidecar it is simply unused. |
| Two decks or two emulators | Each channel holds its own focus. Unchanged. |
| Credential rotation | Token generation invalidates (`streamdeck_auth`). Unchanged. |

## 7. Acceptance criteria

1. `streamdeck_logs_test.exs` passes **unmodified** after C1 (the oracle for
   "same groups").
2. New neutral-module tests cover the § 5.1–5.2 rules directly:
   - **Mutation A:** change `!= :lt` to `== :gt` in the attach comparison.
     The boundary test fails.
   - **Mutation B:** drop `kind` from the identity. The twin test fails.
3. `git grep -n "StreamdeckKeyFaceContract" -- src/lib/aiur/` is empty. No
   core (non-web) module depends on the visual contract.
4. After C2, building core with `packages/streamdeck` absent from the
   checkout succeeds. Proof: temporarily move the directory in a worktree and
   run `mix compile`. The sidecar build still embeds the contract, and both
   agreement tests pass.
5. Hold-to-dictate and targeting re-proof:
   - all listed deck tests pass;
   - a manual check on the owner's hardware: hold Mic, speak, release, Send to
     the focused agent, then answer a focused Command by voice;
   - or, where hardware is unavailable, the `/streamdeck` emulator for
     targeting plus the latency test for voice. State which one was run.
6. No change to `streamdeck:fleet` event names or payload shapes
   (`docs/streamdeck-channel.md`).

## 8. Chunks

### MP-R6-C1 — Extract device-neutral event anchors

- **Outcome:** a pure, documented anchoring module that E4 and the deck both
  use. `StreamdeckLogs` keeps presentation only.
- **Dependencies:** E4 contract reconciliation (§ 5) for the API names. C2-T01
  for the vocabulary, or define it in C1-T01 and have C2 consume it.
- **Tickets:**
  - MP-R6-C1-T01: create the neutral module with `anchor/2`, the identity, the
    origin and the badge vocabulary. Move the existing private functions
    verbatim.
  - MP-R6-C1-T02: make `StreamdeckLogs.project/1` and `load/1` delegate to it.
    Pass `bus: 40, transcript: 50` explicitly.
  - MP-R6-C1-T03: add unit tests for the attach boundary, nil timestamps,
    twins and the origin fallback (with mutation proofs).
- **Tests:** § 7.1–7.2.

### MP-R6-C2 — Invert visual-contract ownership

- **Outcome:** the daemon owns the deck protocol and visual contract file. The
  sidecar consumes it. Core compiles without `packages/streamdeck`.
- **Dependencies:** C1-T01 (vocabulary home). Phase C RQ2 (file home).
- **Tickets:**
  - MP-R6-C2-T01: move `key-face-contract.json` to the daemon-owned path
    chosen in RQ2. Update `@contract_path`.
  - MP-R6-C2-T02: make the sidecar build (`packages/streamdeck/scripts/build-package.mjs`,
    `tsconfig`) import or copy it from that path. Keep
    `key-face-contract.test.ts` byte-agreement.
  - MP-R6-C2-T03: add a CI step that compiles core with the package directory
    absent (§ 7.4).
- **Tests:** both agreement tests; the package build test
  `scripts/test/build-package.test.mjs`.

### MP-R6-C3 — Classify shared versus presentation; voice delegation

- **Outcome:** a written classification (the § 1.2 table) in
  `docs/streamdeck-channel.md`, and the voice availability delegation landed.
  No renames.
- **Dependencies:** MP-R5-C1-T04.
- **Tickets:**
  - MP-R6-C3-T01: add a "Shared projections vs deck presentation" section to
    `docs/streamdeck-channel.md`, plus one line in
    `website/docs-app/guide/stream-deck.md`: "the dashboard never needs the
    sidecar".
  - MP-R6-C3-T02: re-verify after R5-C1-T03 and R5-C1-T04. The deck voice path
    uses `Aiur.Voice` and the `voice_start` replies are unchanged
    (`streamdeck_channel_test.exs:1089-1095`).
- **Tests:** existing deck suites. Manual re-proof (§ 7.5).

## 9. Open questions

**Owner (Kevin):**

1. Confirm that no Stream Deck behaviour change is intended. That includes
   keeping the `"streamdeck"` actor id on dictated Command answers (#2156).
2. Is the hardware re-proof (§ 7.5) on your deck required before C2 merges, or
   is emulator plus automated tests acceptable?

**Research (Phase C):**

- RQ1: Do `AgentEventFeed.list/2` entries carry a stable per-entry id or
  sequence usable as an anchor position? Answer from `agent_event_feed.ex` and
  `IssueLog`.
- RQ2: Where should the daemon-owned contract file live: `src/priv/…`, or a
  small `packages/aiur-deck-protocol`? Decide by what the npm release and the
  sidecar build can reach without the source tree.
- RQ3: Does `StreamDeckGrid.dependency_ready?/2` have a non-deck consumer
  beyond the `status_report.ex:1452` comment? If it is only a comment, keep it
  in place.

## 10. Plan refresh

- After MP-R1: place the neutral anchor module per the `PRJ` #28 decision, and
  update paths in E4 tickets.
- After MP-R2: if per-ticket sequences exist, amend § 5.1 to order by
  sequence, with timestamp as the fallback.
- After the E4 contract is final: rename the provisional module and link the
  contract from C1 tickets.
