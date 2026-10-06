---
contract_id: MP-CT-listener-mode
owner_feature: MP-E7
shared_with: Khala (`@khala/contracts/m1/listening-mode`)
consumers: [MP-E3, MP-E4, MP-E5, MP-E6, MP-N6, MP-R6]
consumes: [MP-CT-harness-adapter, MP-CT-identity-and-capabilities, MP-CT-events-and-replay, MP-CT-conversations-transcripts-anchors]
status: draft
base_main_sha: 45a290e3
khala_ref: origin/main 99e72a43 (2026-10-06)
date: 2026-10-06
---

# Contract: listener mode

A listener mode is a per-agent setting that controls **when an inbound
conversation message may surface inside the agent's session**. It does not
change admission, trust, approval, pause or capacity. The vocabulary and
semantics are shared with Khala (D13); transports, authorization, persistence
and copy stay per product.

Khala citations are at Khala `origin/main` `99e72a43`. The local Khala
checkout is on a stale branch; do not cite it.

## 1. Vocabulary

| Mode | One line | Khala UI copy (`apps/web/src/features/channel/AgentPresencePanel.tsx:139`) |
| --- | --- | --- |
| `steer` | Surface at the earliest proved safe boundary **inside** the active turn. | "Steer · interrupts" |
| `sync` | Hold while a turn is active; surface at the turn boundary. **Default.** | "Sync · next turn" |
| `async` | Persist only. The agent reads when it chooses. Never inject, wake or start a turn. | "Async · on demand" |

- Values: `steer | sync | async` (`packages/contracts/src/delivery/listening-mode.ts:6,16`).
- Default: `sync` (`packages/contracts/src/m1/listening-mode.ts:8`; D13).
- An unknown or invalid stored value decodes to `sync`
  (`m1/listening-mode.ts:18-22`).
- **Hard cancellation is not a listening mode** (Khala
  `docs/product/internal-mode/listening-modes.md:25`). aiur's existing
  `:interrupt` policy (`turn/interrupt` then a new turn) and pane Ctrl+C are
  *controls*, not modes. See §4 for the one sanctioned emulation.
- Name collision: aiur's `Aiur.ExecutorListener` (`executor_listener.ex`) is
  a bus consumer for Executor wakes. It is unrelated to listener modes.

## 2. Scope: which inbound items obey the mode

| Inbound item | Obeys mode? | Why |
| --- | --- | --- |
| Conversation message from a human or the Executor to a worker (dashboard drawer, CLI `aiur message`, HTTP `messages`, Stream Deck, voice transcript, TUI chat pane) | **Yes** | D15: E4 writes go "through the listener mode". |
| Message to the Executor session (MP-E3) | **Yes** | Same contract, hook transport (§8). |
| Command (Decision) answer delivered to the asker (MP-E2) | **No** | Authoritative answer with its own route (`decision_dispatch.ex:51-63`, command contract §7). A held native question is answered in-band regardless of mode. |
| Orchestrator event digests (reviews, CI, blockers) | **No** | Orchestrator wake policy (`delivery_policy.ex:64-86`) stays as is. |
| Pause, resume, interrupt, stop | **No** | Controls (D15 keeps controls where they are). |

Khala's scope is channel messages from other participants; the rule "not
admission, trust, approval, pause" is the same (`listening-modes.md:10-13`).

## 3. Semantics (normative)

Boundaries, in order of earliness:

- **tool boundary** — a tool call finished inside the active turn
  (Claude/Codex `PostToolUse` hook; app-server `tool_completed` notification).
- **native mid-turn input** — the harness accepts input into the live turn
  without cancelling it (Codex `turn/steer`; Claude interactive input queue).
- **prompt boundary** — the harness is about to process a new user prompt
  (`UserPromptSubmit`).
- **turn boundary** — the turn ended (`Stop`; app-server `turn/completed`).
- **idle** — no turn is active and the agent is running (not paused).

Rules:

1. `steer`: deliver at the earliest of tool boundary or native mid-turn
   input; if neither occurs before the turn boundary, deliver there. If idle,
   start a turn now. **Never silently queue a steer message as `sync`**
   (`listening-modes.md:268-272`): if the harness has no proved mid-turn
   boundary, the *effective* mode is not `steer` (§4).
2. `sync`: buffer while a tool or turn is active; at the turn boundary
   the scheduler MAY claim all pending messages as one batch. aiur delivers
   one message per turn boundary, in arrival order, because
   `OperatorWaitLog` and transcript anchors are keyed per request
   (`agent_runner/queue_drain.ex:399-408`; MP-E7-C3-T02). If idle,
   start a turn now (aiur today wakes an idle running agent,
   `delivery_policy.ex:177-180`).
3. `async`: arrival only persists. Never inject, never wake an idle or
   sleeping agent, never start a turn (`listening-modes.md:336-338`). The
   agent reads through a pull tool (§7).
4. **Paused agents** (operator pause, budget hold, self-pause): no mode
   delivers until resume, except that aiur's existing rule letting input
   lift a cooperative self-pause (`delivery_policy.ex:106-131`) applies to
   `steer` and `sync` only.
5. **Ordering:** within one agent, messages surface in acceptance order.
   A batch is never split across modes.
6. **Mode is read at claim time.** A message already claimed for delivery
   keeps the mode it was claimed under.
7. **Idempotency:** a send with the same `client_request_id`, target and
   text returns the first `delivery_id` (aiur `message_id`, #2717,
   `agent_chat.ex:22-25`).
8. **Sync is never claimed at a tool boundary**, including the OpenAI-compat
   in-process `:tool_result` checkpoint, which today inserts operator text
   mid-turn (`open_ai_compat/coding_agent.ex:222-244`). Only `steer` may be
   claimed there (MP-E7-C3-T02).

## 4. Support, requested and effective mode

Each `(harness, mode)` pair has a support status (Khala
`delivery/listening-mode.ts:7-9`): `proven | experimental |
blocked_without_wrapper | unsupported | unknown`. The status set is not
extended, because Khala's decoders reject unknown values and keys
(`messaging/decode.ts:94-101`, `delivery/decode.ts:70-80` at `99e72a43`).
Instead the steer support entry carries an optional field
`steer_carrier: native | emulated_interrupt` (spec v1, MP-E7-C1-T05):

- `steer_carrier: emulated_interrupt` — the harness has no non-destructive mid-turn input;
  steer is carried by aiur's existing hard-interrupt path (cancel the active
  turn, then start a turn with the message). This is today's
  `AgentChat.send/3` default (`agent_chat.ex:27`). It is offered **only if
  the owner accepts it** (DESIGN-E7 decision E7-D2) and is always shown as
  "steer (interrupts current turn)".

A control record carries `requested` and derives `effective` plus
`effective_reason` (Khala `ListeningModeView`,
`delivery/listening-mode.ts:144-149`). Rules:

- `effective = requested` when its support is `proven` or `experimental`
  (for steer with `steer_carrier: emulated_interrupt`, only when E7-D2
  accepts it).
- Otherwise `effective = sync` when sync is supported, else `async`, and
  `effective_reason` names the missing capability. The UI must show both.
- A harness with no proved sync boundary is forced to `async` (Khala:
  codec-less harnesses, `packages/agent/src/client-impl.ts:50-51`).
- `effective` is recomputed when the running transport changes
  (fallback `claude-repl → claude`, RC promotion), using the running
  backend's `delivery_primitives` read through
  `Capabilities.harness_delivery/3` (MP-R7-C2-T03), **never**
  `running_entry.control`, which is stale after a transport change (finding
  R7-C1-F1; fixed by MP-E7-C2-T04).

## 5. Setting the mode

Shared command content (Khala wire, `m1/listening-mode.ts:6-9`):

```json
{ "v": 1, "agent": "<agent id>", "mode": "steer|sync|async" }
```

aiur's command (CLI, HTTP, LiveView) adds fields for its own concurrency
model (prior KTD4 and the Decision API pattern):

```json
{ "v": 1, "agent_ref": "<instance>/<ticket identifier>", "mode": "sync",
  "expected_version": 3, "idempotency_key": "…", "actor": "human|executor" }
```

- **Who may set it:** the operator (human) for any agent of the instance.
  Whether the Executor may set a worker's mode is owner question E7-Q3.
  Khala accepts the command only from the room owner
  (`client-impl.ts:370-386`).
- **Conflicts:** compare-and-set on `expected_version`; a stale write gets
  `409 mode_conflict` with the current record. (Khala's CAS design is
  unimplemented; its m1 runtime keeps last-writer-wins by event time,
  `client-impl.ts:379`.)
- **Durability:** aiur persists the mode per *ticket run* in a file under
  the runtime state dir, after the `SessionHandle` pattern (survives agent
  respawn and daemon restart, cleared at terminal cleanup; MP-E7-C2-T01,
  lifetime per E7-D5). Pending **messages** are not durable today:
  `AgentQueueStore` is in-memory (`agent_queue_store.ex:2-3`), so a daemon
  restart loses unclaimed items; their receipt becomes `unknown` (§7). Khala
  persists per channel binding (`mode.json`, member state key
  `com.khala.listening_mode`).
- **Event:** in wave 3 the change is an in-process PubSub broadcast
  (MP-E7-C2-T04). Once MP-R2 registers it, aiur publishes
  `ticket.<id>.agent.listen-mode.changed` with
  `{requested, effective, effective_reason, version, actor}` (MP-E7-C2-T05,
  wave 4; topic owned by MP-R2's registry).

## 6. Mode transitions

| From → to | Pending messages |
| --- | --- |
| `steer` ↔ `sync` | Stay queued; delivered at the new mode's next boundary. |
| any → `async` | Unclaimed messages become pull-only. |
| `async` → `steer`/`sync` | **Divergence.** Khala advances the cursor and never injects the backlog (`packages/agent/src/mode.ts:11-22`). aiur default (proposed): inject a one-line notice "N earlier messages are waiting; read them with `aiur_read_messages`", never the bodies. Shared field `backlog_on_leave_async: skip \| notice`. Owner decision E7-D4. |

## 7. Receipts and the async pull

Send API (consumed by MP-E4 §9):
`send(conversation_ref, text, client_request_id) → delivery_id`.

| Receipt | Meaning | aiur queue status today |
| --- | --- | --- |
| `accepted` | stored; mode decides when | `:pending` |
| `held_async` | stored, pull-only | new |
| `harness_queued` | handed to the harness, not yet in context | `:delivered` (claimed) |
| `in_context` | the transcript shows the message | `:consumed` / transcript match |
| `read` | pulled by the agent (async) | new |
| `failed` | not delivered; reason given | `:failed` |
| `outcome_unknown` | caller timed out; may still be stored | `{:error, {:outcome_unknown, _}}` (`agent_chat.ex:53-55`) |
| `unknown` | the item is not found (for example after a daemon restart); never reported as `failed` | item absent from `AgentQueueStore` |

Async pull: an agent tool `aiur_read_messages(since_cursor?) → {messages, cursor}` (named after the existing `aiur_*` tools; MP-E7-C5-T01)
that acks by advancing a per-agent cursor (CAS, as Khala's
`advanceCursor`, `packages/agent/src/inbox.ts:51-61`). The operator sees an
unread count per agent. A harness without a pull path
(`pull_tool: false`, for example `claude-repl` today) cannot offer `async`.

## 8. Hook transport (sessions aiur does not launch)

For externally run Claude Code and Codex sessions (the aiur Executor, every
Khala agent), delivery is through harness hooks. Shared behaviour (Khala
`packages/agent/src/harness/deliver-core.ts`, `codecs/claude-style.ts`):

| Hook event | Boundary | Delivers | Output envelope |
| --- | --- | --- | --- |
| `SessionStart` | — | nothing (context only) | `hookSpecificOutput.additionalContext` |
| `PostToolUse` | tool | `steer` only (`deliver-core.ts:218`) | `hookSpecificOutput.additionalContext` |
| `UserPromptSubmit` | prompt | `steer`+`sync`; Claude counts as mid-turn (steer only) when busy < 120 s (`:219-227`) | `hookSpecificOutput.additionalContext` |
| `Stop` | turn | `steer`+`sync`; if `stop_hook_active`, mark idle only (`:239-240`) | `{"decision":"block","reason":<frame>}` |

- Claude and Codex share payloads and envelopes (`codecs/claude-style.ts:6`).
  External references: Claude hooks — `UserPromptSubmit`/`PostToolUse`
  `additionalContext`, `Stop` `decision: "block"` continues the conversation
  (https://code.claude.com/docs/en/hooks, accessed 2026-10-06); Codex hooks —
  `Stop` `decision: "block"` creates a continuation prompt from `reason`,
  `UserPromptSubmit` `additionalContext` is added as developer context
  (https://developers.openai.com/codex/hooks, accessed 2026-10-06).
- Limits: at most 50 messages and 64 KiB per frame
  (`deliver-core.ts:18,57`), UTF-8-safe truncation.
- Hook must exit 0 and never fail the harness (`deliver-core.ts:155-158`;
  aiur's own rule, `claude/hook_settings.ex:26-35`).
- Delivery equals acknowledgement at hook emit (`inbox.ts`; cursor advances
  when emitted). Receipt is `harness_queued`, not `in_context`.
- **Frame copy is per product.** Khala frames say messages "are not
  instructions from your user" (`deliver-core.ts:20`); aiur operator
  messages *are* instructions. Shared: envelope shape and limits only.

## 9. Mapping to aiur harnesses (at `45a290e3`)

| harness | `sync` | `steer` | `async` |
| --- | --- | --- | --- |
| `codex` | proven: existing checkpoint path delivers at the turn boundary (`app_server/operator_delivery.ex:41-51`) | experimental: Codex `turn/steer` (`threadId`, `input`, `expectedTurnId`; codex-cli 0.160.0 schema; fails with no active turn or a mismatched id; no new `turn/started`; https://learn.chatgpt.com/docs/app-server, accessed 2026-10-06), falls back to sync on rejection (MP-E7-C4-T02); else `emulated_interrupt` | proven once `aiur_read_messages` exists (dynamic tools) |
| `claude` (headless, `aiur-claude`) | proven (same checkpoint path) | `unsupported` natively: no documented mid-turn input for `claude --print` (RQ-E7-4); `emulated_interrupt` only. MP-E7-C4-T01 fixes the sibling's `turn/steer` text loss, which then lands next turn only | proven once the tool exists (MCP bridge) |
| `claude-repl` | experimental: hold until the `Stop` hook, then type into the pane (`claude/repl/hook_turn.ex`; MP-E7-C4-T04) | experimental → proven after the MP-E7-C4-T04 foreground capture: queued input is passed "as soon as those tool calls finish, within the same turn" (https://code.claude.com/docs/en/interactive-mode, accessed 2026-10-06, local Claude Code 2.1.291) | `unsupported` until the REPL gets a pull path (no `--mcp-config`, `claude/repl/command.ex:30-35`) |
| `muse` | proven: `ifBusy: "queue"` (`muse/coding_agent.ex:24`) | experimental: MSP `turn/steer` (`expectedTurnId`, `commandId`; `IfBusy = queue \| steer \| replace`; Muse 1.4.3 schema; MP-E7-C4-T03) | proven once `aiur_read_messages` exists (session MCP, `muse/session.ex:75`) |
| `kimi`/`deepseek`/`openrouter` | proven (checkpoint; never claimed at `:tool_result`, §3 rule 8) | native boundary exists: operator text inserted after each tool result (`open_ai_compat/coding_agent.ex:222-244`); support status `experimental` until a steer ticket claims it | proven once the tool exists |
| `gemini` *(ACP; only if PR #2870 merges, RC-22)* | proven: a message becomes a queued turn (`gemini/coding_agent.ex:20`, `gemini/turn.ex:103-112` @ `c1fc6f84`) | `emulated_interrupt` only: urgent → ACP `session/cancel`, then a new turn (`gemini/turn.ex:220-223`, `gemini/protocol.ex:46-48`); no non-cancelling input | possible once `aiur_read_messages` exists (MCP tools bound per turn, `gemini/turn.ex:17`) |
| Executor (external, MP-E3) | via hooks (§8) | via hooks (§8) | via `aiur executor-wait`-style pull |

Today's entry-point defaults (`:interrupt` for `AgentChat`, `:checkpoint`
for HTTP, `:auto` for the TUI; R7 plan F3) are replaced by "the agent's
effective mode" in MP-E7-C3. That is a behaviour change (Bucket 2), so per
RC-05 MP-E7-C3 routes every send through the listener entry point behind the
internal application env `config :aiur, :listener_send_routing`
(`:legacy` default | `:listener`). Under `:legacy` each entry point resolves
to today's policy and the MP-R7-C1 characterization suite passes unchanged.
It is not an operator config key (E7-D7 is an owner item). MP-E7-C7-T04
flips the default and deletes the legacy branch after DESIGN-E7 decision
E7-D6.

## 10. Shared versus per product

| Shared (one package, §11) | aiur only | Khala only |
| --- | --- | --- |
| Mode literals, default, decoder; support statuses; requested/effective rule; boundary rules §3; transition table §6 with `backlog_on_leave_async`; hook boundary mapping §8; Claude/Codex hook stdin parser and envelope renderer; frame limits; conformance goldens | Elixir scheduler over `AgentQueueStore`; app-server, MSP and tmux transports; `steer_carrier: emulated_interrupt` behaviour; CAS command; hook envelope rendering in Elixir (MP-E7-C6-T04); ticket-run persistence; frame copy; CLI/dashboard UI; Command exclusion | Matrix event `com.khala.listening_mode.v1` and member-state echo; room-owner authorization; channel inbox files; idle-wake ladder; web UI |

## 11. Packaging and versioning (resolves MP-Q1; evidence in MP-E7 plan)

- The shared artifact is language-neutral: `listening-mode.v1.schema.json`
  (command, control record, support map), `scheduler.v1.json` (decision
  table: mode × boundary × activity → deliver?), and golden fixtures (hook
  stdin → stdout, per harness × event × mode × count), plus a TypeScript
  reference implementation.
- It is homed in the Khala monorepo as one publishable package and released
  through Khala's tag-driven npm workflow. aiur vendors the JSON files at a
  pinned version with a checksum and runs the goldens against its Elixir
  scheduler in CI. aiur does **not** ship a Node hook: the daemon renders the
  hook envelope in Elixir, tested against the shared envelope-only goldens,
  and the hook is a plain `curl` command (MP-E7-C6), because `aiur-cli`
  requires Node `>=18` and Khala's packages need `^22.18.0 || >=24.11.0`.
  Hook goldens hold the envelope only; frame wording stays per product.
- Wire content carries `v: 1`. Adding a mode or a support status is a major
  change (old decoders map unknown modes to `sync`, which would silently
  downgrade). While Khala's decoders reject unknown keys (Khala `object(...)`,
  `delivery/listening-mode.ts:154`; `messaging/decode.ts:94-101`,
  `delivery/decode.ts:70-80`), adding a field is also breaking. So v1 ships
  `backlog_on_leave_async` and `steer_carrier` from its first release
  (MP-E7-C1-T05 lands before MP-E7-C1-T03).

## 12. Security and privacy

- Setting a mode requires the same authority as sending a message to that
  agent (aiur: writable dashboard credentials or local CLI; paired devices
  per D19 later). A mode change is audited with `actor`.
- `async` must not leak content into the agent context; only the notice in
  §6 crosses without a pull.
- The hook endpoint for external sessions stays loopback-scoped like
  `POST /api/v1/:id/claude-hook` (`claude/hook_settings.ex:39-44`).
- Message text is logged only where it is today (`agent_chat.ex:32`
  previews 500 bytes); listener code adds no new text logging.
</content>
</invoke>
