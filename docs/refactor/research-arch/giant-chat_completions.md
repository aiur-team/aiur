# Decomposition: `src/lib/aiur/opencode/chat_completions.ex` (1127 lines)

Behavior-preserving split of the chat-completions bridge into ten modules, following the
house style proven by the prewarm/attach simplification: pure policy modules extracted from
the process/conn plumbing, one source of truth per fact, one dependency direction, thin
entrypoint. Wire-shape ownership per `src/AGENTS.md` ("opencode-specific config and wire
shapes belong in `Aiur.Opencode.Protocol`") is honored by carving the operator-wrapper wire
shape into a dedicated sibling of `Protocol` rather than folding it into `Protocol` itself
(which is already 452 lines, i.e. over the 200-line norm and due its own census).

Repo conventions verified before naming: nested namespaces exist and follow the standard
Elixir layout (`Aiur.Orchestrator.TrackedSet` → `lib/aiur/orchestrator/tracked_set.ex`,
`Aiur.Config.Paths`, `Aiur.PaneManager.Layout`), and "policy" is an established suffix for
pure decision modules (`Aiur.Opencode.SlotPolicy`). Rule used here: concerns specific to the
chat-completions endpoint nest under `Aiur.Opencode.ChatCompletions.*` in
`src/lib/aiur/opencode/chat_completions/`; concerns that are opencode wire/protocol facts
usable by other bridge surfaces stay flat under `Aiur.Opencode.*`.

---

## 1. Function / responsibility census

All line numbers refer to the current file. Sizes are body lines including their heavy doc
comments (which carry load-bearing race documentation and must move with the code).

### Constants & module setup — lines 1–61 (~61)
- Aliases (1–20); `@stream_marker_prefix/_regex`, `@nudge_marker_regex` (22–29);
  `@turn_marker_prefix/_regex` (31–39); `@max_body_bytes`, `@watchdog_ms` (41–42);
  `@default_segment_threshold_ms` (43–49); `@heartbeat_ms` (50–56);
  `@empty_continuation_idle_factor` (57–61).
- Note: `@turn_marker_prefix "__aiur_turn__:"` duplicates
  `Aiur.Opencode.TurnMarkers.marker_prefix/0` (turn_markers.ex:23) because it is needed as a
  compile-time literal for binary-prefix pattern matching.

### A. HTTP entry & marker routing — lines 63–123 (~61)
- `handle/2` (64–77, 14) — public entry from `Bridge` (`bridge.ex:19`); model→identifier,
  placeholder short-circuit.
- `handle_identified/3` (79–84, 6) — extract last user text or 400.
- `handle_identified_text/4`, turn-marker clause (86–99, 14) — parse `__aiur_turn__:`,
  run the shadowed-operator-text coalescing defense, open the turn stream.
- `handle_identified_text/4`, stream-marker clause (101–113, 13) — nudge → empty stream;
  `__aiur_stream__:msg_…` → replay; else 400.
- `handle_identified_text/4`, operator-text clause (115–123, 9) — repost shadowed markers,
  then dispatch operator text.

### B. Turn-stream SSE engine (bridge-as-LLM) — lines 125–341 (~217)
- `stream_codex_turn/3` (140–190, 51) — subscribe (AgentPubSub + DebugLog) **before**
  ActiveTurns lookup; open chunked SSE; arm watchdog + heartbeat; build segment state;
  three branches: `:active` loop / `{:closed, reason}` late close / `:not_found` phantom.
- `codex_turn_stream_loop/6` (201–296, 96) — the receive loop: `{:transcript_event, e}`,
  `{:event_debug, entry}` (EventRow-filtered ticker rows), `{:aiur_turn_done, id, parent, r}`
  close, `:heartbeat` (doubles as idle-boundary clock; empty-delta keepalive),
  `{:turn_watchdog, parent}` (reschedule-vs-close; `Orchestrator.mark_sleeping/1`; 💤 notice;
  `"timeout"` finish), catch-all drop.
- `unsubscribe_stream/1` (303–307, 5) — drop BOTH subscriptions; the Bandit
  process-reuse duplication fix.
- `stream_event_then_continue/7` (312–328, 17) — chunk one delta, then boundary-close or loop.
- `close_segment/5` (335–341, 7) — post continuation marker FIRST, unsubscribe, then `"stop"`.

### C. Pure stream policy — lines 343–399 (~57), public + unit-tested
- `segment_boundary?/3` (349–351) — tool/command block end past threshold.
- `idle_segment_boundary?/6` (360–380) — threshold age + heartbeat-scaled silence;
  empty-continuation ×2 factor; segment-0 exception.
- `watchdog_action/2` (391–399) — `{:close, silent_ms}` vs `{:reschedule, delay_ms}`.

### D. Caller / writer resolution — lines 401–425 and 960–989 (~55)
- `originating_writer/2` (406–419) — bearer→slot→base_url→SessionWriterRegistry; `nil`
  disables segmentation (degrades to long-held SSE).
- `segment_threshold_ms/0` (421–423) — app-env override of the segment threshold.
- `now_ms/0` (425).
- `resolve_session_for_replay/2` (960–978) — exact `(identifier, base_url)` lookup;
  **deliberately no fallback** to "any writer for identifier" (duplicate-key registry
  ordering would read the wrong serve's DB view).
- `caller_base_url/1` (980–989) — bearer token → TokenRegistry → SlotRegistry →
  `Slot.snapshot/1` → base_url.

### E. Finalization & finish reason — lines 427–460 (~34)
- `finalize_stream/3` ×3 clauses (427–445) — `{:failed, r}` / `:input_required` /
  default close messages.
- `finish_reason_for/1` (447–460, public + tested) — always `"stop"`; the `"tool_calls"`
  busy-loop hazard is documented here and pinned by tests.

### F. Transcript-delta rendering — lines 462–642 (~181), mostly public + heavily tested
- `transcript_delta/2` (464–480) — role filter; `:user` always drops (RC parity).
- `format_delta/2`, `/3` (482–543) — command `$`-blockquote, tool edit/read rows,
  `\`\`\`diff` fences, reasoning italics, alert/system blockquotes.
- `render_dim_blockquote/2` (556–562); `normalize_escaped_newlines/1` (564–573);
  `edit_diff_from_payload/1` (575–603); `looks_like_unified_diff?/1` (605–610).
- `bar_connector/2` (612–639, public + tested); `blockquote_role?/1` (641–642).

### G. Operator dispatch — lines 644–759 and 851–854 (~125)
- `dispatch_user_text/4` (644–653) — validate + authorize, then route; 400/401 taxonomy.
- `route_turn/4` (655–659) — stream vs non-stream.
- `stream_turn/3` (678–702) — ack-fast contract: close SSE `"stop"` as soon as
  `AgentChat.send` accepts (clears opencode's QUEUED indicator within ~1s).
- `non_stream_turn/3` (704–718).
- `send_operator/3` (720–741) — normalize; `""` → `{:ok, :noop}` (never forwarded);
  `AgentChat.send(…, delivery_policy: :auto, turn_id: …)`.
- `log_operator_text/3` (743–759) — the greppable `opencode_bridge operator_text` trace.
- `emit_error_and_close/3` (851–854).

### H. Operator-text wire normalization — lines 761–849 (~89), public + heavily tested
- `operator_text_trace/2` (761–789) — pure `wrapped`/`dropped` bug-signature fields (#332).
- `@operator_wrapper_regex` (791–818) — the opencode `<system-reminder>` envelope shape,
  verified against the opencode binary; deliberately un-anchored, CRLF-tolerant.
- `normalize_operator_text/1` (820–840); `scan_operator_messages/1` (842–849).

### I. SSE / JSON response encoding — lines 661–676, 856–877, 909–917, 1116–1126 (~60)
- `build_chunk/2` (661–676, public + tested) — OpenAI `chat.completion.chunk` wire shape.
- `chunk/4` (856–874) — Jason-encode + `Plug.Conn.chunk`; on `{:error, closed}` logs once
  and returns conn unchanged (never crashes the turn).
- `delta/1` (876–877); `empty_stream/1` (909–917) — `data: [DONE]`.
- `json/3` (1116–1120); `random_id/0` (1122–1126).

### J. Model → identifier — lines 879–907 (~29)
- `identifier_from_model/1` ×2 (879–902) — accepts `issue-<id>` and `aiur/issue-<id>`;
  `placeholder_model?/1` (904–907).

### K. Replay (`__aiur_stream__` synthetic-marker round-trip) — lines 919–957, 991–996 (~45)
- `replay_message_as_stream/3` (919–945) — `Db.fetch_message_with_parts/2`, stream parts,
  not-found system message.
- `chunk_part/3` (991–996).

### L. Auth — lines 1096–1114 (~19)
- `maybe_authorized/2` (1096–1107) — bearer valid per TokenRegistry (identifier-independent).
- `auth_failed_body/0` (1109–1114).

### M. Request-body parsing & coalescing defenses — lines 998–1094 (~97)
- `last_user_text/1` (998–1008); `message_user_text/1` (1010–1015);
  `text_from_parts/1` (1079–1084).
- `trailing_user_texts/1` (1017–1032, public + tested) — trailing user run since last
  assistant message.
- `synthetic_marker_text?/1` (1034–1037).
- `dispatch_shadowed_operator_texts/2` (1039–1057) — coalescing defense A (text behind
  routed marker).
- `repost_shadowed_markers/3` (1059–1077) — coalescing defense B (marker behind routed text).
- `validate_body/1` (1086–1094) — 64 KiB cap, UTF-8, control-char strip.

---

## 2. Module NAME MAP (the contract)

| # | Module | File (under `src/lib/`) | Responsibility | ~LOC |
|---|--------|--------------------------|----------------|-----:|
| 1 | `Aiur.Opencode.ChatCompletions` (slimmed, same name) | `aiur/opencode/chat_completions.ex` | Thin HTTP entrypoint for `POST /v1/chat/completions`: model→identifier, last-user-text classification (turn marker / stream marker / nudge / operator text), the two coalescing defenses, delegation to the handlers below. | ~170 |
| 2 | `Aiur.Opencode.ChatCompletions.TurnStream` | `aiur/opencode/chat_completions/turn_stream.ex` | The bridge-as-LLM SSE engine for one `__aiur_turn__` segment: subscribe→lookup→loop lifecycle, heartbeat/watchdog timers, segment close, stream finalization. Runs entirely in the Bandit request process. | ~220 |
| 3 | `Aiur.Opencode.ChatCompletions.StreamPolicy` | `aiur/opencode/chat_completions/stream_policy.ex` | Pure close/idle/watchdog decisions plus the timing constants behind them (`heartbeat_ms/0`, `watchdog_ms/0`, `segment_threshold_ms/0`, `empty_continuation_idle_factor/0`). | ~100 |
| 4 | `Aiur.Opencode.ChatCompletions.DeltaRenderer` | `aiur/opencode/chat_completions/delta_renderer.ex` | Transcript event → markdown SSE delta: role filtering/dropping, command/tool/diff/reasoning formatting, blockquote-bar connectors. | ~200 |
| 5 | `Aiur.Opencode.ChatCompletions.OperatorDispatch` | `aiur/opencode/chat_completions/operator_dispatch.ex` | Deliver validated operator text to the agent via `AgentChat.send` (`:auto` policy) and ack over SSE/JSON; delivery-vs-drop trace logging; noop-on-empty contract. | ~140 |
| 6 | `Aiur.Opencode.OperatorText` | `aiur/opencode/operator_text.ex` | Pure opencode `<system-reminder>` operator-wrapper wire shape: extract every wrapped operator message (`normalize/1`), derive the `wrapped`/`dropped` trace fields (`trace/2`). Sibling of `Protocol` in the wire-shape isolation boundary. | ~110 |
| 7 | `Aiur.Opencode.ChatCompletions.Replay` | `aiur/opencode/chat_completions/replay.ex` | `__aiur_stream__:<msg_id>` synthetic-marker replay: resolve the caller's session (exact writer, no fallback), read just-written rows via `Db`, stream them as assistant deltas. | ~90 |
| 8 | `Aiur.Opencode.ChatCompletions.Caller` | `aiur/opencode/chat_completions/caller.ex` | Identify and authorize the opencode-serve behind a bridge request: bearer→`TokenRegistry`→`SlotRegistry`→`Slot.snapshot` base_url (`base_url/1`), token validity (`authorize/1`, `auth_failed_body/0`), originating session writer (`writer/2`). | ~90 |
| 9 | `Aiur.Opencode.ChatCompletions.Sse` | `aiur/opencode/chat_completions/sse.ex` | OpenAI-compatible response encoding and disconnect-tolerant conn writes: `build_chunk/2`, `chunk/4`, `delta/1`, `empty_stream/1`, `finish_reason_for/1` (always `"stop"`), `json/3`, `random_id/0`. | ~110 |
| 10 | `Aiur.Opencode.ChatCompletions.TurnRequest` | `aiur/opencode/chat_completions/turn_request.ex` | Pure request-body interpretation: `last_user_text/1`, `trailing_user_texts/1`, parts flattening, `synthetic_marker_text?/1`, `validate_body/1`. No side effects. | ~100 |

Total ≈ 1,320 LOC (growth is moduledocs/`@spec`s; every file lands at or under the ~200-line
guiding target, versus 1,127 in one file today).

### Function moves per module

- **ChatCompletions keeps:** `handle/2`, `handle_identified/3`, `handle_identified_text/4`
  (3 clauses), `identifier_from_model/1`, `placeholder_model?/1`,
  `dispatch_shadowed_operator_texts/2`, `repost_shadowed_markers/3`, the marker
  prefix/regex attributes (compile-time literals required for binary-prefix matches).
- **TurnStream:** `stream_codex_turn/3` (public name: `stream/3`), `codex_turn_stream_loop/6`,
  `stream_event_then_continue/7`, `close_segment/5`, `unsubscribe_stream/1`,
  `finalize_stream/3`, `now_ms/0`.
- **StreamPolicy:** `segment_boundary?/3`, `idle_segment_boundary?/6`, `watchdog_action/2`,
  `segment_threshold_ms/0`, plus `@watchdog_ms`/`@heartbeat_ms`/
  `@default_segment_threshold_ms`/`@empty_continuation_idle_factor` exposed as functions.
- **DeltaRenderer:** `transcript_delta/2`, `format_delta/2`, `format_delta/3`,
  `bar_connector/2`, `blockquote_role?/1`, `render_dim_blockquote/2`,
  `normalize_escaped_newlines/1`, `edit_diff_from_payload/1`, `looks_like_unified_diff?/1`.
- **OperatorDispatch:** `dispatch_user_text/4`, `route_turn/4`, `stream_turn/3`,
  `non_stream_turn/3`, `send_operator/3`, `log_operator_text/3`, `emit_error_and_close/3`.
- **OperatorText:** `normalize_operator_text/1` → `normalize/1`, `operator_text_trace/2` →
  `trace/2`, `scan_operator_messages/1`, `@operator_wrapper_regex`.
- **Replay:** `replay_message_as_stream/3` → `stream/3`, `chunk_part/3`,
  `resolve_session_for_replay/2`.
- **Caller:** `maybe_authorized/2` → `authorize/1`, `caller_base_url/1` → `base_url/1`,
  `originating_writer/2` → `writer/2`, `auth_failed_body/0`.
- **Sse:** `build_chunk/2`, `chunk/4`, `delta/1`, `empty_stream/1`, `finish_reason_for/1`,
  `json/3`, `random_id/0`.
- **TurnRequest:** `last_user_text/1`, `message_user_text/1`, `text_from_parts/1`,
  `trailing_user_texts/1`, `synthetic_marker_text?/1`, `validate_body/1`.

### Dependency direction (acyclic, one direction)

```
Bridge (Plug router, unchanged)
  └─ ChatCompletions ── TurnRequest (pure)
        ├─ TurnStream ── StreamPolicy (pure)
        │      ├─ DeltaRenderer ── Style
        │      ├─ Sse
        │      ├─ Caller ── TokenRegistry / SlotRegistry / Slot / SessionWriterRegistry
        │      └─ TurnMarkers / ActiveTurns / AgentPubSub / DebugLog / EventRow / Orchestrator
        ├─ OperatorDispatch ── OperatorText (pure), Sse, AgentChat
        ├─ Replay ── Caller, Sse, Db, SessionWriterRegistry
        └─ Sse (error/empty-stream responses), Caller, TurnMarkers (marker repost)
```

Leaves are pure or registry-read-only; nothing below the entrypoint calls back up. No
GenServers are introduced — every extracted module is plain functions executing in the
Bandit request process, matching the "pure policy over call chains" house rule.

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

Every wave leaves `mix test` green and moves ≤400 lines (lib + test). Test describe-blocks
move with their functions in the same wave and are renamed to the new module — no
`defdelegate` shims are left behind (grep confirms the only cross-file caller of these
helpers is `src/test/aiur/claude/transcript_test.exs`, updated in Wave 3).

- **Wave 0 — characterization backfill (no code moved).** Add Plug.Test-driven tests for the
  currently-unpinned conn paths before touching them: phantom-turn (`:not_found`) closes
  with `"stop"`, late close (`{:closed, reason}`) renders the reason, nudge marker returns
  an empty stream, operator-text ack closes `"stop"` immediately, `chunk/4` tolerates a
  closed conn, replay not-found renders `**system:** message not found`. Uses started
  `ActiveTurns`/registries and messages sent to `self()`; the receive-loop cases drive
  `stream_codex_turn` from a test process. This is where hotspot row 5 says to spend.
- **Wave 1 — `Aiur.Opencode.OperatorText`** (pure; ~110 lib + ~130 test moved). Move
  normalization + trace + wrapper regex; `send_operator`/`log_operator_text` call the new
  module. The #332 pins move verbatim to `operator_text_test.exs`.
- **Wave 2 — `StreamPolicy` + `TurnRequest`** (pure; ~200 lib + ~130 test). Timing constants
  become `StreamPolicy` functions; loop/timer call sites in `chat_completions.ex` read them
  from there (one source of truth for every threshold).
- **Wave 3 — `DeltaRenderer`** (~200 lib + ~250 test). Move rendering + its describe blocks;
  update `transcript_test.exs` alias from `ChatCompletions` to `DeltaRenderer`.
- **Wave 4 — `Sse` + `Caller`** (~200 lib + ~50 test). Move encoding/conn-write helpers and
  the bearer→slot→writer resolution; `build_chunk`/`finish_reason_for` tests move.
- **Wave 5 — `Replay` + `OperatorDispatch`** (~230 lib). First conn-handling extraction; the
  Wave 0 characterization tests pin the ack-fast contract, the 401/400 taxonomy, and the
  no-fallback replay resolution across the move.
- **Wave 6 — `TurnStream`** (~230 lib). The receive loop moves last, as a near-verbatim cut:
  every function it calls already lives at its final address, so the diff on the
  riskiest code is pure relocation. `chat_completions.ex` lands at its final ~170 lines.

Rationale: leaves-first ordering means each later wave moves code whose dependencies are
already final, and the highest-risk code (the receive loop with its subscribe/timer/close
semantics) moves in the smallest possible diff, after characterization exists.

---

## 4. Risks

### Concurrency / state / timing semantics that must be preserved verbatim

1. **Request-process affinity.** `AgentPubSub.subscribe_agent/1`, `DebugLog.subscribe/0`,
   both `Process.send_after` timers, and the `receive` loop all assume `self()` is the
   Bandit handler that owns the conn. Extraction must be plain function calls — never a
   `Task`, `GenServer`, or spawned loop.
2. **Subscribe-before-lookup** (lines 143–150): the stream subscribes to AgentPubSub before
   the `ActiveTurns.lookup`, so a close broadcast racing the lookup still lands in the
   mailbox and is drained by the loop. Reordering deadlocks the SSE until the watchdog.
3. **Unsubscribe on every exit path** (lines 298–307): opencode reopens a completion per
   segment on one keep-alive connection and Bandit reuses the handler process; a missed
   `unsubscribe_stream/1` stacks subscriptions → N× duplicate rendering. All five exit
   paths (turn done, watchdog close, segment close, late close, phantom) must keep it.
4. **Heartbeat cadence** (lines 50–56): 15s empty-delta keepalive must stay under
   opencode's ~28–30s client timeout or the multi-subscriber duplication returns. The
   heartbeat also doubles as the idle-boundary clock — moving the constant without moving
   the `idle_segment_boundary?` coupling breaks the ×2 empty-continuation factor.
5. **Watchdog is not a wall-clock cap** (lines 260–291): `last_event_at` is bumped only by
   real deltas (never heartbeats); `watchdog_action/2` reschedules for the remaining
   window. Also preserves the `Orchestrator.mark_sleeping/1` side effect, the 💤 system
   message, and the sole non-`"stop"` finish (`"timeout"`).
6. **Segment-close ordering** (lines 330–341): post the continuation marker to the
   originating writer FIRST (it queues behind held operator text), then unsubscribe, then
   the `"stop"` chunk. Aiur state untouched — parent turn stays `:active`.
7. **Coalescing-defense ordering** (lines 86–123): shadowed operator texts dispatch BEFORE
   the segment stream opens; shadowed markers repost BEFORE operator text dispatches.
   Both derive from the same `trailing_user_texts/1` — keep one source.
8. **`finish_reason_for/1` always `"stop"`** (lines 447–460): `"tool_calls"` with no payload
   makes opencode busy-loop reopening the request until the ActiveTurns entry expires
   (~60s), pegging CPU.
9. **`chunk/4` disconnect tolerance** (lines 856–874): a closed conn logs at debug and
   returns the conn unchanged; a `MatchError` here kills the whole turn's rendering.
10. **Parent-id keying** (lines 137–141): `ActiveTurns` and `:aiur_turn_done` are keyed by
    the bare parent id from `TurnMarkers.parse_turn_id/1`; an exact-key lookup with the
    `-s<N>` suffixed id phantom-closes every segment.
11. **Replay writer resolution has NO fallback** (lines 947–978): with `:duplicate` registry
    keys, "any writer for identifier" reads a different serve's DB view and produces false
    `message not found`.
12. **Operator noop-on-empty + trace contract** (lines 720–789): `""` after normalization
    acks `{:ok, :noop}` and forwards nothing; `wrapped=true dropped=true` is the greppable
    #332 bug signature and must keep deriving from the same scan as `normalize/1`.
13. **Marker-prefix literals**: `@turn_marker_prefix` duplicates
    `TurnMarkers.marker_prefix/0` because binary-prefix pattern matches need compile-time
    literals. Either keep the literal with its cross-reference comment or set the attribute
    from `TurnMarkers.marker_prefix()` at compile time — do not introduce runtime
    indirection into the match clauses.

### Hotspot-map evidence (docs/refactor/research-history-hotspots.md)

Row 5 puts `src/lib/aiur/opencode/` at ~17 incidents, explicitly citing "operator messages
lost in panes (#332 recurred after 3 fixes)" — the exact seam `OperatorText` +
`OperatorDispatch` carve out — and the warm-marker/attach race chain (PR #65→#74→#83→#96).
Characterization priority #6 names `chat_completions.ex` directly ("operator-message
preservation"). Cross-cutting theme 1 (timing/submission races: "anything that sends then
assumes needs an explicit ack") covers items 2, 4, 6 above; theme 10 (guard/optimization
regressions: every new skip/cap clipped a legitimate case first) is precisely the
segmentation/idle/watchdog guard cluster in `StreamPolicy` — its boundary conditions are
already well pinned by tests and those pins must move with it un-weakened.

### Existing test pins

- `src/test/aiur/opencode/chat_completions_test.exs` (480 lines) — pure helpers only:
  `build_chunk`, `format_delta`, `transcript_delta`, `segment_boundary?`,
  `idle_segment_boundary?`, `watchdog_action`, `trailing_user_texts`,
  `normalize_operator_text`, `operator_text_trace`, `finish_reason_for`, `bar_connector`.
- `src/test/aiur/opencode/bridge_test.exs` — end-to-end routing pins: 401 auth, 400 invalid
  model, bare `issue-X` model accepted, placeholder → empty `[DONE]` stream.
- `src/test/aiur/claude/transcript_test.exs` (lines 193–227) — `format_delta/3` diff-fence
  integration for claude-repl events (alias updates in Wave 3).
- `src/test/aiur/events/debug_log_test.exs` — the global-topic subscription semantics the
  `{:event_debug, …}` loop clause depends on.
- Collaborator contracts pinned separately: `active_turns_test.exs` (phantom/late-close
  states, subscriber displacement), `turn_markers_test.exs` (parse/post/retry semantics),
  `session_writer_registry_test.exs`, `token_registry_test.exs`, `slot_registry_test.exs`.

### Missing characterization (fill in Wave 0)

Nothing currently executes: `stream_codex_turn`'s three branches; the receive loop's
transcript-delta streaming, `event_debug` identifier filtering, heartbeat idle-close,
and watchdog close (incl. `mark_sleeping` and the `"timeout"` finish); `close_segment`'s
marker-before-stop ordering; both coalescing defenses' side effects; the replay
found/not-found paths and no-fallback resolution; `stream_turn`'s ack-fast `"stop"`;
`chunk/4`'s closed-conn tolerance; `validate_body`'s size/UTF-8/control-char taxonomy.
All are drivable with Plug.Test conns, started registries, and messages to `self()`; the
minimum bar before Waves 5–6 is the Wave 0 list above.
