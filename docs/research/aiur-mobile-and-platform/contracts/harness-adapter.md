---
contract_id: MP-CT-harness-adapter
owner_feature: MP-R7
consumers: [MP-E7, MP-E2, MP-E3, MP-E4, MP-R1]
status: draft
base_main_sha: 45a290e3
date: 2026-10-06
---

# Contract: harness adapter

How aiur drives one coding-agent harness session. It is the existing
`Aiur.CodingAgent.Backend` behaviour (`src/lib/aiur/coding_agent/backend.ex`)
made explicit, plus a derived **delivery-primitives** descriptor and reserved
optional callbacks for MP-E7 (listener modes) and MP-E2 (native questions).

This contract is Elixir-internal. The cross-product part (shared with Khala)
is the listener-mode contract ([listener-mode.md](listener-mode.md)), which
references the primitives below.

## 1. Identity

| Field | Meaning | Source today |
| --- | --- | --- |
| `harness_id` | registry key: `codex`, `claude`, `claude-repl`, `muse`, `kimi`, `deepseek`, `openrouter` (`fake` in test) | `coding_agent/registry.ex:7-16` |
| `family` | provider family (`codex`, `claude`, `muse`, …) | registry entry `:family` |
| `transport` | `app_server_stdio` \| `tmux_pane` \| `msp_stdio` \| `in_process_http` \| `acp_stdio` (Gemini, conditional on PR #2870, RC-22) | new, derived (R7-C2) |
| `session.thread_id` | harness-native session/thread id; may be `nil` until the first turn | `backend.ex:24-27` |
| `session.resumed` | `true` only after a successful rejoin | `backend.ex:24-27` |

`harness_id` values are a superset of Khala's harness ids for the shared
families (`claude`, `codex`, `muse`; Khala `packages/contracts/src/m1/harness.ts:20-33`
at `99e72a43`). aiur's `claude-repl` maps to Khala `claude`; aiur's headless
`claude` has no Khala counterpart (Khala never launches headless sessions).

## 2. Callbacks

Required (unchanged from `backend.ex:117-139`): `start_session/2`,
`run_turn/4`, `stop_session/1`, `normalize_event/1`,
`send_operator_message/2`.

Optional, existing: `interrupt/1` (`backend.ex:141-147`).

Optional, **reserved** (added by the feature named; absent ⇒ capability
`:none`):

| Callback | Added by | Purpose |
| --- | --- | --- |
| `steer(session, payload, expected_turn_id)` → `{:ok, ref}` \| `{:error, :no_active_turn \| :turn_mismatch \| term}` | MP-E7 | Non-cancelling mid-turn input. Codex `turn/steer`; Muse `turn/start` with a steer `ifBusy` value (to verify); REPL pane input. |
| `reply_native_question(session, native_ref, %{question_id => [answer]})` → `:ok` \| `{:error, :not_pending \| :session_gone}` | MP-E2 | Complete a held native ask-the-user request. Name and shape adopted from `command-request-and-resolution.md` §10. |
| `release_native_question(session, native_ref, text)` → same returns | MP-E2 | Release a held request; the default text reproduces today's non-interactive answer (`codex/user_input_answers.ex:6`). |
| `transcript_source/1` (existing `:transcript` registry module) | MP-E4 | Provider records → entries with `provider_msg_id`, `tool_call_id`, `turn_id`, and session-boundary signals (`conversations-transcripts-anchors.md` §14). |

Runner control messages stay in-band, as today (`backend.ex:40-50`):
`{:pause_agent, request_id[, generation]}` and
`{:agent_queue_updated, identifier, item_id, deliver_now?}`.

## 3. Capability descriptor

Existing registry keys keep their meaning (`backend.ex:58-115`). R7 adds one
derived read-only structure per **running** agent (computed from the running
entry, never the requested backend, because of fallback and RC promotion):

```text
delivery_primitives:
  turn_boundary_start  : boolean   # can start a new turn with operator text after the current one
  mid_turn_inject      : :native | :none          # non-cancelling input into a live turn
  hard_interrupt       : :in_band | :out_of_band | :none
  native_queue         : boolean   # harness folds typed input itself (claude-repl)
  pull_tool            : boolean   # agent can call an aiur tool to read messages (needs dynamic tools)
  hook_boundaries      : [:prompt | :tool | :stop]   # boundaries observed via hooks (claude-repl)
native_question        : :in_band_hold | :defer_resume | :none      # MP-E2 (names from command contract §10)
```

Values at `45a290e3` (R7-C2 must reproduce, nothing more). Phase C research
(MP-R7-C2-T01) settled RQ-R7-1 and RQ-R7-4. The descriptor is derived from a
registry `delivery:` map (data per entry), not hard-coded per harness, and
`transport` is declared there rather than inferred.

| harness | transport | turn_boundary_start | mid_turn_inject | hard_interrupt | native_queue | pull_tool | hook_boundaries | native_question |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| codex | app_server_stdio | yes | none (upstream `turn/steer` unused; MP-E7-C4) | in_band | no | yes (dynamic tools) | [] | none (auto-answered) |
| claude | app_server_stdio | yes | none (`aiur-claude` steer defect, MP-E7-C4-T01) | in_band | no | yes (MCP bridge) | [] | none |
| claude-repl | tmux_pane | yes | native — Claude Code passes queued input "as soon as those tool calls finish, within the same turn" (https://code.claude.com/docs/en/interactive-mode, accessed 2026-10-06; aiur pins no `claude` version, foreground capture in MP-E7-C4) | out_of_band (Ctrl+C) | yes | **no** (`claude/repl/command.ex:30-35`, no `--mcp-config`) | [prompt, tool, stop] | none |
| muse | msp_stdio | yes (`ifBusy: queue`) | none (receipt allows `steered`; steer value unverified, RQ-E7-2) | in_band | no | yes (aiur MCP, `muse/session.ex:75`) | [] | none |
| kimi / deepseek / openrouter | in_process_http | yes | native (operator text inserted after each tool result inside the turn, `open_ai_compat/coding_agent.ex:222-244`; test `open_ai_compat/coding_agent_test.exs:638`) | none | no | yes | [] | none |
| gemini *(only if PR #2870 merges, RC-22)* | acp_stdio | yes (operator text becomes a queued turn) | none | in_band (ACP `session/cancel`) | no | yes (aiur MCP bound per turn) | [] | none (`session/request_permission` is an approval, stays with policy) |

**After MP-E7-C4 (wave 4).** These values change only when the named
ticket ships: `codex` `mid_turn_inject: :native` via app-server `turn/steer`
(MP-E7-C4-T02; codex-cli 0.160.0 schema, `TurnSteerParams{threadId, input,
expectedTurnId}`); `muse` `:native` via MSP `turn/steer` (MP-E7-C4-T03; Muse
1.4.3 schema, `IfBusy = queue | steer | replace`); `claude-repl` stays
`:native` and gains the foreground capture (MP-E7-C4-T04). Headless `claude`
stays `:none`: no documented mid-turn input for `claude --print`
(RQ-E7-4); MP-E7-C4-T01 only fixes the sibling's text loss.

Consumers (MP-E7 effective mode) read the running backend's descriptor
through `Capabilities.harness_delivery/3` (MP-R7-C2-T03), never
`running_entry.control`.

Muse's and OpenAI-compat's `send_operator_message/2` have no production
caller; runtime delivery is the runner drain or checkpoint.

**Running entry, not dispatch.** Finding R7-C1-F1: the running entry's
`:control` delivery flags are computed once at dispatch from the requested
backend (`orchestrator/dispatcher.ex:2549`) and are not recomputed on
fallback (`claude-repl → claude`) or RC promotion, although the real backend
is recorded in `running_entry.session_execution.backend`
(`orchestrator/state.ex:441-461`). R7-C2-T03 exposes the running backend
(`source: :session | :dispatch`) without changing the existing map; the fix
is MP-E7-C2-T04.

**Gemini/ACP row (RC-22).** The `gemini` harness exists only in draft PR
#2870 (aiur-team/aiur, open and draft, head `c1fc6f84`, checked 2026-10-06);
it is not at `45a290e3`. Evidence at the PR head:
`coding_agent/providers/gemini.ex` (`can_interrupt: true`,
`safe_checkpoints: []`, `resumable: true`, `default_command: "gemini --acp"`),
`gemini/coding_agent.ex:20` (`send_operator_message` returns
`{:error, :gemini_messages_require_queued_turn}`), `gemini/turn.ex:103-112,220-223`
and `gemini/protocol.ex:46-48` (urgent queue update sends `session/cancel`,
then the message starts the next turn), `gemini/turn.ex:17` (per-turn aiur MCP
binding). Rule: if #2870 merges before MP-R7-C2 starts, R7-C2 declares this
row as values and the C1 registry contract test covers it; otherwise the row
is a **future adapter** and lands directly in the harness package (R7-C4).

### 3.1 Registry keys added by MP-R7-C3/C4 (decoupling only)

| Key | Ticket | Replaces |
| --- | --- | --- |
| `:launch_telemetry` | MP-R7-C3-T03 | `agent_runner/session_lifecycle.ex` naming `Aiur.Claude.Telemetry` |
| `:display_tailer` | MP-R7-C3-T03 | the same file naming `Aiur.Claude.DisplayTailer` |
| `:children` | MP-R7-C4-T01 | `aiur.ex:432` starting `Aiur.Claude.Telemetry` by name |

Pane and orchestrator interrupts call a `CodingAgent.interrupt/2` facade that
dispatches to the optional `interrupt/1` callback (MP-R7-C3-T04). The agent
tool surface is `Aiur.AgentTools.*` (MP-R7-C3-T01 moves `Aiur.Codex.DynamicTool`
there). Module renames to an `Aiur.Harness.*` namespace are **dropped**: MP-R1
keeps components logical until the migration-plan §5 promotion test passes
(MP-R7-C4-T02), so "harness package" below means the logical component.

## 4. Normalized events (in-process)

Adapters already emit through `on_message`. The contract names the subset
consumers rely on; payloads keep existing keys:

- `turn_started`, `turn_completed`, `turn_failed`, `turn_interrupted`
- `operator_turn_started` (an operator message became a turn;
  `app_server/operator_delivery.ex:100-105`)
- `tool_completed` (a safe boundary; used by MP-E7 steer)
- `native_question_requested` / `native_question_resolved` (MP-E2; new)
- delivery acknowledgement: `acknowledge_queue_item_delivery/3` with provider
  metadata (`orchestrator/operator_messages.ex:177-185`)

Whether any becomes an MP-R2 bus topic is MP-E7/MP-R2's decision.

## 5. Outcomes

Return values follow prior KTD4 (typed complete / held / unknown): `{:ok, _}`,
`{:paused, _}` (suspend, never failure; `backend.ex:120-125`), `{:error, _}`.
A send whose receipt is unknown (timeout) is reported as unknown, never as
failed (`agent_chat.ex:51-55`, #2717).

## 6. Requirements for MP-E2 native ask-the-user capture

What E2 needs from this contract (D10: only native ask-the-user tools become
Commands; approvals stay with policy):

1. **Classification before auto-answer.** Codex `item/tool/requestUserInput`
   arrives as a server request with an `id` (`codex/approvals.ex:148-169`).
   Today it is answered immediately (approve-label heuristic or the
   non-interactive answer, :241-281). The adapter must first classify:
   approval-shaped (options are approve/allow labels,
   `codex/user_input_answers.ex:70-91`) stays with policy; anything else
   emits `native_question_requested`.
2. **Hold without blocking the turn loop.** The adapter keeps the JSON-RPC
   request id unanswered, issues an opaque `native_ref` (internally
   `{harness_id, thread_id, turn_id, request_id}`), and keeps receiving frames.
   While held, the turn reports "waiting on Command" so the stall detector
   does not count it (command contract §10 item 6). RQ: Codex's own timeout
   for an unanswered `requestUserInput` (documented as experimental,
   `tool/requestUserInput`, 1–3 questions with optional `isOther`;
   https://learn.chatgpt.com/docs/app-server, accessed 2026-10-06).
3. **Normalized question payload:** `questions[{id, header, question,
   options[{label, description}], multi_select, allow_other}]`. Codex keys
   answers by question `id` (`{"answers": {id: {"answers": [label]}}}`,
   `codex/approvals.ex:244`). Claude `AskUserQuestion` keys answers by
   question **text** (`"answers": {"Which framework?": "React"}`, multi-select
   joined by commas) and is answered by a `PreToolUse` hook returning
   `permissionDecision: "allow"` with `updatedInput` echoing `questions` plus
   `answers`; it can also be seen in `PermissionRequest` with
   `tool_name: "AskUserQuestion"` (https://code.claude.com/docs/en/hooks,
   accessed 2026-10-06, docs reference Claude Code v2.1.2xx). The adapter
   must carry both keys so E2 never has to know the harness.
4. **Correlation to the asking session**, not the ticket: answers return
   through `reply_native_question/3` on the session that asked, which fixes
   the baseline gap "answers are addressed to the ticket"
   (`decision_dispatch.ex:65`).
5. **Capability `native_question`:** `:in_band_hold` (Codex app-server),
   `:in_band_hold` via a blocking `PreToolUse` hook for `claude-repl` (Claude — needs a long
   hook timeout and a hook that waits; today's hooks are fire-and-forget
   `curl -m 2`, `claude/hook_settings.ex:42-44`), `:defer_resume` when the
   harness must be answered at once and the human answer later arrives as a
   message, `:none` (headless
   `claude --print` via `aiur-claude` until the sibling forwards
   `AskUserQuestion`; OpenAI-compat; Muse until its protocol is checked —
   `muse/turn_loop.ex` maps `userInput/request` to
   `:native_user_input_required` per baseline).
6. **Release rules:** on pause, stop, turn end or session loss the adapter
   calls `release_native_question/3`, which reproduces today's
   non-interactive answer, and emits `native_question_resolved` with
   `reason`. A late answer returns `{:error, :not_pending}` (E2 then falls back
   to message delivery, command contract §7.3).
7. **Executor as requester (D12):** the Executor has no adapter (no aiur-run
   session). Capture there is hook-based in the Executor's own Claude Code or
   Codex session, using the same hook installer as MP-E7 §8 of the
   listener-mode contract. This is an E2/E3 dependency on E7, not on R7.
8. **Attached (external) sessions.** E3/E4 need adapters for sessions aiur
   did not start (the Executor). Such an adapter implements only
   `transcript_source`, `send_operator_message` (via hooks, listener-mode §8)
   and the native-question callbacks; `start_session/2` and `run_turn/4` are
   absent. R7 reserves this "attached" profile; MP-E3 defines it.

## 7. Versioning

Internal behaviour; versioned with aiur. Adding an optional callback or a
descriptor field is additive. Renaming a `harness_id` is breaking (it is in
config `agent.routing` values and labels).
</content>
</invoke>
