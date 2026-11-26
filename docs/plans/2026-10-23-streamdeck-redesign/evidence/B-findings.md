# Group B findings: view state, input model, views, priority, instance switch

Researched at `6a7d6b445`. Paths are relative to the worktree root. Dial numbers in
this pack: "dial 1..4" = hardware encoder index 0..3 = the A..D letters in the code and
the guide.

## 1. Three navigation state machines exist today

| Where | What | Used in production? |
| --- | --- | --- |
| `packages/streamdeck/src/mode.ts:9-207` (`transitionMode`, `commandKeys`) | Pure TS mode machine: grid / cmd / logs / settings / commands | **No.** It is imported only by `test/mode.test.ts`, `dial.ts:14` (types) and `logs.ts:36` (types). It is dead code apart from its types. |
| `packages/streamdeck/src/controller.ts:45-352` + `controller/state.ts:14,168-285` | The physical sidecar's real machine (`createPhysicalController`): `pressKey` (104), `turn` (177), `pressDial` (219), `handleReport` (267) | Yes, physical deck |
| `src/lib/aiur_web/live/streamdeck_live.ex:62-90,154-194` + `live/streamdeck_live/modes.ex` | The `/streamdeck` emulator's machine in LiveView assigns (`sd_mode`, `sd_active`, `grid_column_offset`, …) | Yes, browser emulator |

The two live machines are kept in step by hand ("parity contract", `mode.ts:99-104`).

## 2. Dials and keys today

- Hardware decode: `packages/streamdeck/src/input.ts:13-33` gives `key` (8), `encoder-button`
  (4) and `encoder-turn` (4, signed ticks). `risingEdges` (36-50) emits only button-down
  edges. **There is no hold or long-press timing anywhere** (`dial.ts` only has the
  press-vs-turn threshold for the on-screen knob, `dial.ts:40,86`).
- Dial A (index 0): press = BACK everywhere (`controller.ts:220`); turn scrolls the transcript in logs (`controller.ts:184-186`).
- Dial B (index 1): turn scrolls the provider panel in grid only (`PROVIDER_SCROLL_ENCODER = 1`, `touchStrip/providerPanel.ts:72`; `controller.ts:204-216`). Press: no action.
- Dial C (index 2): no turn and no press action.
- Dial D (index 3): turn pages agent columns / events / Commands (`controller.ts:187-203`); press cycles the window, enters logs from cmd, or approves a Command (`controller.ts:219-265`).
- Demo chord = presses of B+C together (`controller/state.ts:255`, `DEMO_CHORD = [1, 2]`). In the new layout these are dial 2 (priority) and dial 3 (instance). Turns do not trip the chord (separate report kind), but a press-to-confirm on dial 3 must not also be one half of the chord.
- Emulator: `streamdeck_live.ex:181-194` handles only `dial-press` back and `cycle-window`; knob labels are fixed placeholders "Focus / Volume / Speed / Page" (`live/streamdeck_live/surface.ex:272-297`).
- Guide table of modes and dials: `website/docs-app/guide/stream-deck.md:9-25`.

## 3. Where view state lives today, and recommendation

- The channel process already holds per-deck session state in assigns:
  `focused_agent`, `focus_token`, `transcript_relay`, `voice_session`
  (`src/lib/aiur_web/streamdeck_channel.ex:41`, `handle_in("focus")` 47-55). One Phoenix
  channel process = one connected deck.
- The emulator holds the same kind of state in its LiveView process.

**Recommendation: server-side per-deck session state.** Put one pure reducer
(`AiurWeb.Streamdeck.Deck.Nav`) in the daemon. The channel keeps its `Nav` struct in
socket assigns; the `/streamdeck` LiveView keeps its own in its assigns. The sidecar
and the emulator send raw gestures (`input` event) and show what the server renders.
Reasons:

1. The server renders the images (decision 2), so it must know view, page, selection and
   drill stack to render anything. A sidecar-owned state would have to be mirrored to the
   server on every change anyway.
2. One reducer replaces three machines (section 1) and retires the parity contract.
3. The channel process already is the per-deck session (section 3 first bullet).

Three things stay in the sidecar because only the device host can do them:

- gesture classification: press vs long press (timing is local; a round trip per poll would be wrong), and turn tick batching;
- microphone hold (audio capture is local, `controller.ts:267-277`);
- instance switching (dial 3): the sidecar owns the socket (`packages/streamdeck/src/main.ts:324-345`), so only it can reconnect to another daemon. The server only shows the list.

Session state is lost when the channel process ends (disconnect). Default: reset to the
default view on reconnect (SD-406 setting); do not add a session registry.

## 4. Build.NowRows: the 9-state taxonomy

Module `AiurWeb.Build.NowRows` (`src/lib/aiur_web/build/now_rows.ex`), called from
`AiurWeb.Build.IndexReader.read_now/2` (`build/index_reader.ex:38-62`). Rows include only
live and retrying agent-owned tickets in this repository (`band?/2`, 79-86). Each row has
`agent.state` (precedence table in the moduledoc, lines 8-20; code 115-157):

| # | `agent.state` | Condition |
| --- | --- | --- |
| 1 | `error` | error work state or UnitsPolicy stuck |
| 2 | `retrying` | retry backoff |
| 3 | `command` | open command count > 0 or waiting for human |
| 4 | `usage_limited` | paused for provider usage limit |
| 5 | `ci_wait` | paused for CI |
| 6 | `parked` | other non-reserving pause, or GitHub budget hold |
| 7 | `paused` | other UnitsPolicy pause |
| 8 | `active` | live and starting/allocated/working |
| 9 | `nil` (unknown) | anything else |

Caveat: `runtime_reason_state/1` (168-175) runs first and passes through the suffix of
the first reason label, so the wire enum is wider: `retries merge-queued ci-red body-fix
paused-usage-limit paused-decision paused-agent blocked handed-off`
(`build/payload_schema.ex:33`). The Build page maps every value to a label and a class
(`src/priv/static/build-home/now-state.js:2-12`) and maps unknown values to "State unknown".
The deck must do the same: an unknown value renders as unknown, never as `active`.

Also per row: `status` (`queued|failed|running`), `pct` (nil when unknown), `agent.model`,
`agent.name`, `agent.pause`, `agent.resume_at`, `agent.effort`, `start`.

Today's deck does **not** use this: `AiurWeb.StreamDeckGrid.project/2`
(`src/lib/aiur_web/stream_deck_grid.ex:39-60`) buckets by
`Aiur.AgentEvents.streamdeck_bucket/1` (`src/lib/aiur/agent_events.ex:298-299`) into 5
states, and the key-face contract enforces exactly those 5
(`src/lib/aiur_web/streamdeck_key_face_contract.ex:12`, `src/priv/streamdeck/key-face-contract.json`).

The queued backlog (tickets with no agent) is not in NowRows. It is the `plan` section
from `AiurWeb.Build.PlannedRows` (`build/planned_rows.ex:20,44`, with `qpos`) and the `nq`
section.

## 5. Features (#5998) and Epics (#5999) data

Both issues are OPEN, `agent:todo`, and **blocked by #5996** (List shows switch,
`agent:rework`).

- #5998 defines a new snapshot block `feature_progress`, keyed by feature-local epic
  (`f-bo-<root>-<lane>`), each `{closed, open, ci_wait, unpublished, total}` (nonnegative
  integer or nil) plus `observed_at`; percentage = closed / total, rounded down.
- #5999 defines `epic_progress`, keyed by general-epic key, `{closed, open, total}` +
  `observed_at`, counted by **label match against every general epic's matchers**
  (multi-count), not by the single resolved epic. Sort: remaining desc, then label.
  Empty state when `general_epics` is `[]`.
- **Neither block exists on main** (`grep feature_progress|epic_progress` in `src/lib` and
  `src/priv/static/build-home`: no hits).
- What does exist: `features[slug].stats` from `Aiur.BuildOrder.FeatureStats`
  (`src/lib/aiur/build_order/index/catalogue.ex:24-28`, `feature_stats.ex:28-58`). Its
  `pct` is **complexity-point weighted** (`feature_stats.ex:15-21,64-70`), so it is not the
  same number as #5998's closed/total. And `counts`, one total per resolved epic
  (`src/lib/aiur/build_order/index.ex:123`), which #5999 says cannot answer remaining per
  area. Using either for the deck would make the deck disagree with the Build page.
- Consequence: SD-203 hard-depends on #5998's server block, SD-204 on #5999's. Both server
  blocks are blocked behind the browser-only #5996. Recommend the planner ask for the
  server block of each to be split out (or #5996 marked a soft dependency of the block).

## 6. BuildQueue priority up/down

- **The Build page has no reorder control.** `BuildLive.handle_event/3`
  (`src/lib/aiur_web/live/build_live.ex:129-176`) has `queue-add` only; nothing in
  `src/lib/aiur_web` or `src/priv/static/build-home` calls reorder.
- The function is `Aiur.BuildQueue.reorder(id, at)` (`src/lib/aiur/build_queue.ex:66-67`),
  used today only by the CLI (`aiur build-queue reorder <id> --to N`,
  `build_queue/mutation_cli.ex:59,78,129`). It moves an item to absolute position `at`
  within its queue (`build_queue/list_mutations.ex:39-47`).
- Limits the deck must surface:
  - not in any queue -> `{:error, :not_queued}` (`list_mutations.ex:104-108`) — true for most live (Now) tickets;
  - in a `:build_order` queue -> `{:unavailable, :not_list}` (`build_queue/sources/executor_list.ex:6-13`, falls out of the `with`): only operator `:list` queues reorder;
  - out of range -> `{:error, :invalid_position}`; server down -> `{:error, :disabled}`; timeout -> `{:error, :outcome_unknown}` (`build_queue.ex:72-77`).
- Current position comes from `Aiur.BuildQueue.show/0` (read model, `build_queue.ex:22-34`) or `qpos` on Build `plan` rows.
- A second, different "priority" exists: `Aiur.AgentChat.prioritize/1` /
  `deprioritize/1` (`src/lib/aiur/agent_chat.ex:123-131`), the orchestrator flag that the
  grid sorts by (`stream_deck_grid.ex:209-216`). The deck dropped its prioritize key for
  it (`mode.ts:51-56`, guide line 25). Decision 3 says "build queue", so SD-206 uses
  `BuildQueue.reorder`, not this flag.

## 7. Multi-instance (#5964) and the dial-3 switcher

- Sub-issues of #5964: MIC-001 #5965, MIC-002 #5970 (`POST /api/v1/control`), MIC-003
  #5968 (**closed**: `aiur --instance <name>` + registry), MIC-004 #5972, MIC-005 #5966
  (closed), MIC-006 #5973, MIC-007 #5969, MIC-008 #5971, MIC-009 #5967, MIC-010 #5974.
  Prerequisites named by the epic: #5945 (per-client bearer tokens), #5947 (claim lease).
  Roster/liveness is #5950 (blocked by the lease work).
- Discovery that exists now: `~/.aiur/remote-instances.yaml` (`version: 1`,
  `instances.<name>.url`, `token_file` or `token_env`), read by
  `packaging/npm/aiur-cli/libexec/engine/remote.sh:3,97-99`. HEAD commit `6a7d6b445`
  ("Add named remote CLI targets (#5994)") is MIC-003.
- The sidecar connects to one daemon from env: `AIUR_PHOENIX_URL` plus the shared
  dashboard basic-auth pair (`packages/streamdeck/src/main.ts:324-345`), POSTing
  `/api/v1/streamdeck/token` with `Authorization: Basic` (`packages/streamdeck/src/channel.ts:68,89-92`;
  route `src/lib/aiur_web/routes/streamdeck.ex:10`). The registry carries bearer tokens,
  which that route does not accept yet.
- **Exact blocker for SD-207: #5945** — its AC2 makes the Stream Deck token route accept
  `Authorization: Bearer`, and AC4 says "The Stream Deck sidecar … send[s] a bearer token
  when one is configured". Without it, each instance needs its own basic-auth pair kept in
  a second, deck-only registry. #5950 is a soft dependency (live/stale label per instance);
  without it the switcher shows only names and the connect result.

## 8. Renderer dependency summary

| Ticket | Needs SD-102 (server renderer)? |
| --- | --- |
| SD-201 nav reducer + `input` event | No. Pure module + channel handler; SD-102/103/104 consume it |
| SD-202 Ticket view | Yes. A 9-state face on the TS renderer would mean growing the 5-state key-face contract in two renderers that SD-104 then deletes |
| SD-203 / SD-204 / SD-205 | Yes. New layouts; no TS path |
| SD-206 dial-2 priority | Server action no; visible result yes (via SD-201 + SD-102/103) |
| SD-207 dial-3 instance switch | No. Sidecar-local; it can ship on the current TS renderer once #5945 lands |
