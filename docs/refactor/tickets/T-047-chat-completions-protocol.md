# T-047: chat_completions: wire shapes into Aiur.Opencode.Protocol

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/opencode/chat_completions.ex` is a 1,127-line giant that mixes the
HTTP entrypoint for `POST /v1/chat/completions`, the bridge-as-LLM SSE receive
loop, pure stream-boundary policy, transcript-delta rendering, operator-text
dispatch, the opencode `<system-reminder>` operator-wrapper wire shape, SQL
replay, caller/auth resolution, OpenAI chunk encoding, and request-body parsing.
`src/AGENTS.md` (line 22-23) mandates that opencode-specific wire shapes live in
the `Aiur.Opencode.Protocol` isolation boundary. The binding decomposition plan,
`docs/refactor/research-arch/giant-chat_completions.md`, honors that rule by
carving the operator-wrapper wire shape into `Aiur.Opencode.OperatorText`, a
**sibling of `Protocol` in the same wire-shape isolation boundary** — NOT by
folding it into `src/lib/aiur/opencode/protocol.ex`, which is already 452 lines
(over the 200-line norm) and is **not modified by this ticket**. That research
doc's §2 name map and §3 wave plan are the contract for this ticket; where this
ticket and that doc appear to differ, the research doc wins.

This is a pure behavior-preserving decomposition. Wire bytes must be identical
before and after: opencode is pinned at 1.17.10 and every shape here
(`chat.completion.chunk` JSON, SSE framing, `data: [DONE]`, the operator-wrapper
regex, finish reasons) is load-bearing against that binary.

## Scope (exact)

Execute the seven waves of `giant-chat_completions.md` §3, **in order, one
commit per wave, with `mix test` green after every wave**. Move code verbatim —
cut and paste function bodies and their doc comments unchanged; the heavy
comments carry load-bearing race documentation and MUST move with their code.
Do not rewrite, reorder clauses, rename variables, or "improve" anything. No
`defdelegate` shims anywhere (the only external caller of the moved public
helpers is `src/test/aiur/claude/transcript_test.exs`, updated in step 5). The
only public function whose module+name+arity must stay put is
`Aiur.Opencode.ChatCompletions.handle/2` — `bridge.ex:19` calls it and
`bridge.ex` is untouched. Every new module gets a `@moduledoc` (1-3 sentences,
factual) and `@spec` on every public `def`. All timing/ordering semantics in
the research doc's §4 risk list (items 1-13) are preserved verbatim; in
particular: extraction is plain function calls only — never a `Task`,
`GenServer`, or spawned process (everything keeps running in the Bandit request
process).

1. **Wave 0 — characterization backfill (no code moved).** Extend
   `src/test/aiur/opencode/chat_completions_test.exs` with `Plug.Test`-driven
   tests that call `Aiur.Opencode.ChatCompletions.handle/2` end-to-end (started
   `ActiveTurns`/registries; messages sent to `self()` for the receive-loop
   cases, driving the turn stream from the test process). Pin, at minimum:
   - phantom turn (`ActiveTurns.lookup/2` → `:not_found`, lines 181-189) closes
     with finish `"stop"`;
   - late close (`{:closed, reason}`, lines 176-179) renders the reason and
     closes;
   - nudge marker (`__aiur_stream__:nudge:<N>`, lines 101-104) returns an empty
     `data: [DONE]` stream;
   - operator-text ack-fast: SSE closes `"stop"` as soon as `AgentChat.send`
     accepts (lines 686-702);
   - replay not-found renders `**system:** message not found` then `"stop"`
     (lines 939-944);
   - `chunk/4` closed-conn tolerance (lines 856-874): define a minimal stub
     adapter module in the test file whose `chunk/2` returns
     `{:error, :closed}`, swap it into a sent conn's `:adapter` field, and
     assert the conn is returned unchanged (no raise);
   - `validate_body/1` taxonomy (lines 1086-1094): >65,536 bytes →
     `{:error, :body_too_large}`; invalid UTF-8 → `{:error, :invalid_utf8}`;
     control chars (except tab/newline/CR) stripped.
   These tests target `handle/2` and public helpers only, so they stay valid
   across all later waves and remain in `chat_completions_test.exs`.

2. **Wave 1 — create `Aiur.Opencode.OperatorText`** at
   `src/lib/aiur/opencode/operator_text.ex` (the wire-shape isolation boundary
   sibling of `Protocol`). Move verbatim from `chat_completions.ex`:
   - `@operator_wrapper_regex` (lines 791-818, comment included, regex
     byte-identical);
   - `normalize_operator_text/1` (lines 820-840) → public `normalize/1`;
   - `operator_text_trace/2` (lines 761-789) → public `trace/2`;
   - `scan_operator_messages/1` (lines 842-849) → stays `defp` inside
     `OperatorText` (both `normalize/1` and `trace/2` must keep deriving from
     this one scan — risk item 12).
   In `chat_completions.ex`, `send_operator/3` (line 725) and
   `log_operator_text/3` (line 752) now call `OperatorText.normalize/1` /
   `OperatorText.trace/2`. Create
   `src/test/aiur/opencode/operator_text_test.exs`; move the
   `normalize_operator_text` and `operator_text_trace` describe blocks (the
   #332 pins) there verbatim, renamed to `normalize`/`trace`.

3. **Wave 2 — create `Aiur.Opencode.ChatCompletions.StreamPolicy`** at
   `src/lib/aiur/opencode/chat_completions/stream_policy.ex` and
   **`Aiur.Opencode.ChatCompletions.TurnRequest`** at
   `src/lib/aiur/opencode/chat_completions/turn_request.ex`.
   - StreamPolicy takes (verbatim): `segment_boundary?/3` (lines 343-351),
     `idle_segment_boundary?/6` (lines 353-380), `watchdog_action/2` (lines
     382-399), `segment_threshold_ms/0` (lines 421-423), plus the attributes
     `@watchdog_ms`, `@heartbeat_ms`, `@default_segment_threshold_ms`,
     `@empty_continuation_idle_factor` (lines 42-61, comments included),
     exposed as public zero-arity functions `watchdog_ms/0`, `heartbeat_ms/0`,
     `empty_continuation_idle_factor/0` (plus the existing
     `segment_threshold_ms/0`). Every timer/loop call site in
     `chat_completions.ex` that read those attributes now calls the
     StreamPolicy function (one source of truth per threshold — risk item 4).
   - TurnRequest takes (verbatim, all made public with `@spec` except
     `message_user_text/1` and `text_from_parts/1` which it may keep private):
     `last_user_text/1` (998-1008), `message_user_text/1` (1010-1015),
     `text_from_parts/1` (1079-1084), `trailing_user_texts/1` (1017-1032),
     `synthetic_marker_text?/1` (1034-1037), `validate_body/1` (1086-1094),
     plus `@max_body_bytes` (line 41). TurnRequest defines its own
     `@turn_marker_prefix "__aiur_turn__:"` and
     `@stream_marker_prefix "__aiur_stream__:"` attributes for
     `synthetic_marker_text?/1` with a comment cross-referencing
     `chat_completions.ex` and `TurnMarkers.marker_prefix/0` (same precedent as
     the existing duplication noted at chat_completions.ex:31-33).
     `chat_completions.ex` KEEPS its own marker prefix/regex attributes (lines
     22-39) — they are compile-time literals required by the binary-prefix
     match clauses at lines 86, 101, 1070 (risk item 13).
   Create `stream_policy_test.exs` and `turn_request_test.exs` under
   `src/test/aiur/opencode/chat_completions/`; move the `segment_boundary?`,
   `idle_segment_boundary?`, `watchdog_action`, `trailing_user_texts`
   describe blocks there verbatim, plus the Wave 0 `validate_body` cases into
   `turn_request_test.exs` retargeted at `TurnRequest.validate_body/1`.

4. **Wave 3 — create `Aiur.Opencode.ChatCompletions.DeltaRenderer`** at
   `src/lib/aiur/opencode/chat_completions/delta_renderer.ex`. Move verbatim:
   `transcript_delta/2` (462-480), `format_delta/2` and `/3` (482-543),
   `bar_connector/2` (612-639) — all public with existing specs — and the
   private helpers `render_dim_blockquote/2` (556-562),
   `normalize_escaped_newlines/1` (564-573), `edit_diff_from_payload/1`
   (575-603), `looks_like_unified_diff?/1` (605-610), `blockquote_role?/1`
   (641-642). Alias `Aiur.Opencode.Style`. Create `delta_renderer_test.exs`
   (same test dir); move the `transcript_delta`, `format_delta`, and
   `bar_connector` describe blocks there. Update
   `src/test/aiur/claude/transcript_test.exs` lines 193-227: alias
   `Aiur.Opencode.ChatCompletions.DeltaRenderer` and call
   `DeltaRenderer.format_delta/3`.

5. **Wave 4 — create `Aiur.Opencode.ChatCompletions.Sse`** at
   `src/lib/aiur/opencode/chat_completions/sse.ex` and
   **`Aiur.Opencode.ChatCompletions.Caller`** at
   `src/lib/aiur/opencode/chat_completions/caller.ex`.
   - Sse takes (verbatim): `build_chunk/2` (661-676), `chunk/4` (856-874),
     `delta/1` (876-877, stays private), `empty_stream/1` (909-917),
     `finish_reason_for/1` (447-460, comment included — always `"stop"`, risk
     item 8), `json/3` (1116-1120), `random_id/0` (1122-1126). All public
     except `delta/1`.
   - Caller takes: `maybe_authorized/2` (1096-1107) → public `authorize/1`
     (conn only; the ignored identifier arg is dropped, comment kept),
     `auth_failed_body/0` (1109-1114) → public, `caller_base_url/1` (980-989)
     → public `base_url/1`, `originating_writer/2` (401-419) → public
     `writer/2`.
   Create `sse_test.exs` and `caller_test.exs` (same test dir). Move the
   `build_chunk` and `finish_reason_for` describe blocks into `sse_test.exs`
   plus the Wave 0 closed-conn `chunk/4` case retargeted at `Sse.chunk/4`.
   `caller_test.exs` pins: `authorize/1` without a Bearer header →
   `{:error, :unauthorized}`; `base_url/1` without a Bearer header → `:error`;
   `auth_failed_body/0` returns the map with `:error` and `:message` keys.

6. **Wave 5 — create `Aiur.Opencode.ChatCompletions.Replay`** at
   `src/lib/aiur/opencode/chat_completions/replay.ex` and
   **`Aiur.Opencode.ChatCompletions.OperatorDispatch`** at
   `src/lib/aiur/opencode/chat_completions/operator_dispatch.ex`.
   - Replay takes: `replay_message_as_stream/3` (919-945) → public `stream/3`;
     private `resolve_session_for_replay/2` (947-978, NO-fallback comment
     included verbatim — risk item 11) and `chunk_part/3` (991-996). Uses
     `Caller.base_url/1`, `Sse.chunk/4`, `Sse.random_id/0`, `Db`,
     `SessionWriterRegistry`.
   - OperatorDispatch takes: `dispatch_user_text/4` (644-653) → public,
     `send_operator/3` (720-741) → public (it is called from
     `chat_completions.ex`'s coalescing defense), and private `route_turn/4`
     (655-659), `stream_turn/3` (678-702, ack-fast comment included),
     `non_stream_turn/3` (704-718), `log_operator_text/3` (743-759),
     `emit_error_and_close/3` (851-854). Uses `TurnRequest.validate_body/1`,
     `Caller.authorize/1`, `Caller.auth_failed_body/0`, `OperatorText`,
     `Sse`, `AgentChat`.
   Create `replay_test.exs` and `operator_dispatch_test.exs` (same test dir);
   move the Wave 0 replay-not-found and ack-fast cases there, retargeted at
   `Replay.stream/3` and `OperatorDispatch.dispatch_user_text/4`.

7. **Wave 6 — create `Aiur.Opencode.ChatCompletions.TurnStream`** at
   `src/lib/aiur/opencode/chat_completions/turn_stream.ex`, a near-verbatim
   cut of the riskiest code, moved last because everything it calls is now at
   its final address. Takes: `stream_codex_turn/3` (125-190, both comment
   blocks included) → public `stream/3`; private `codex_turn_stream_loop/6`
   (192-296), `stream_event_then_continue/7` (309-328), `close_segment/5`
   (330-341), `unsubscribe_stream/1` (298-307), `finalize_stream/3` (427-445),
   `now_ms/0` (425). Attribute reads become `StreamPolicy.watchdog_ms()`,
   `StreamPolicy.heartbeat_ms()` (including the
   `div(StreamPolicy.watchdog_ms(), 60_000)` in the 💤 notice);
   `originating_writer` becomes `Caller.writer/2`; rendering calls go to
   `DeltaRenderer`; chunk writes to `Sse.chunk/4`. Preserve exactly:
   subscribe-before-lookup ordering (risk 2), unsubscribe on all five exit
   paths (risk 3), marker-post-FIRST-then-unsubscribe-then-`"stop"` in
   `close_segment` (risk 6), watchdog reschedule arithmetic +
   `Aiur.Orchestrator.mark_sleeping/1` + `"timeout"` finish (risk 5), bare
   parent-id keying (risk 10). Create `turn_stream_test.exs` (same test dir)
   with direct `TurnStream.stream/3` tests for the phantom-close and
   late-close branches (Plug.Test conn + started `ActiveTurns`).
   Finally, slim `chat_completions.ex` to the entrypoint that remains:
   `handle/2`, `handle_identified/3`, `handle_identified_text/4` (3 clauses),
   `identifier_from_model/1` (879-902), `placeholder_model?/1` (904-907),
   `dispatch_shadowed_operator_texts/2` (1039-1057, now calling
   `TurnRequest.trailing_user_texts/1`, `TurnRequest.synthetic_marker_text?/1`,
   `TurnRequest.validate_body/1`, `OperatorDispatch.send_operator/3`,
   `Sse.random_id/0`), `repost_shadowed_markers/3` (1059-1077, now calling
   `Caller.writer/2`), and the marker prefix/regex attributes (22-39).
   Shadowed-text-dispatch-BEFORE-segment-open and marker-repost-BEFORE-
   operator-dispatch ordering is unchanged (risk 7).

8. Run `mix format` on every touched file before each commit. Do not add any
   module to `ignore_modules` in `src/mix.exs` — do not touch `mix.exs` at all.

## Files

- Create: `src/lib/aiur/opencode/operator_text.ex`,
  `src/lib/aiur/opencode/chat_completions/stream_policy.ex`,
  `src/lib/aiur/opencode/chat_completions/turn_request.ex`,
  `src/lib/aiur/opencode/chat_completions/delta_renderer.ex`,
  `src/lib/aiur/opencode/chat_completions/sse.ex`,
  `src/lib/aiur/opencode/chat_completions/caller.ex`,
  `src/lib/aiur/opencode/chat_completions/replay.ex`,
  `src/lib/aiur/opencode/chat_completions/operator_dispatch.ex`,
  `src/lib/aiur/opencode/chat_completions/turn_stream.ex`,
  `src/test/aiur/opencode/operator_text_test.exs`,
  `src/test/aiur/opencode/chat_completions/stream_policy_test.exs`,
  `src/test/aiur/opencode/chat_completions/turn_request_test.exs`,
  `src/test/aiur/opencode/chat_completions/delta_renderer_test.exs`,
  `src/test/aiur/opencode/chat_completions/sse_test.exs`,
  `src/test/aiur/opencode/chat_completions/caller_test.exs`,
  `src/test/aiur/opencode/chat_completions/replay_test.exs`,
  `src/test/aiur/opencode/chat_completions/operator_dispatch_test.exs`,
  `src/test/aiur/opencode/chat_completions/turn_stream_test.exs`
- Modify: `src/lib/aiur/opencode/chat_completions.ex`,
  `src/test/aiur/opencode/chat_completions_test.exs`,
  `src/test/aiur/claude/transcript_test.exs` (alias update only, lines 193-227)
- Test: all 9 new test files above, plus the modified
  `chat_completions_test.exs` and `transcript_test.exs`

## Out of scope

- `src/lib/aiur/opencode/protocol.ex` — DO NOT modify. The name map
  deliberately siblings `OperatorText` beside `Protocol` instead of extending
  it (`Protocol` is over the 200-line norm and gets its own census separately).
- `src/lib/aiur/opencode/bridge.ex` — unchanged; it calls the unchanged
  `ChatCompletions.handle/2`.
- `src/lib/aiur/opencode/turn_markers.ex`, `active_turns.ex`,
  `session_writer.ex`, `session_writer_registry.ex`, `event_row.ex`, `db.ex`,
  `style.ex`, `token_registry.ex`, `slot.ex`, `slot_registry.ex`, `config.ex`
  — collaborators, read-only here.
- `src/lib/aiur/agent_runner.ex` (T-034..T-036 territory).
- `src/mix.exs` — no `ignore_modules` additions, no other edits.
- Any timing constant value, regex, log message string, finish reason, or wire
  shape — byte-identical moves only.
- Any new `GenServer`, `Task`, `spawn`, or process boundary.
- Anything under `src/test/aiur/regression/`.
- The opencode pin (1.17.10) and anything under `website/`.

## Inventory-IDs

From `docs/refactor/feature-inventory/oc.md`, implemented by the files this
ticket touches (all must survive byte-for-byte in behavior):
FI-OC-004, FI-OC-005, FI-OC-007, FI-OC-008, FI-OC-010, FI-OC-013, FI-OC-014,
FI-OC-015, FI-OC-016, FI-OC-017, FI-OC-018, FI-OC-021, FI-OC-022, FI-OC-023,
FI-OC-024, FI-OC-026, FI-OC-027, FI-OC-028, FI-OC-029, FI-OC-030.
Adjacent, constrained-but-untouched: FI-OC-001 (bridge router), FI-OC-009,
FI-OC-011, FI-OC-012 (ActiveTurns), FI-OC-019, FI-OC-020 (TurnMarkers),
FI-OC-025 (EventRow), FI-OC-056, FI-OC-061 (Protocol).

## Characterization-tests

- `src/test/aiur/regression/warm_marker_semantics_test.exs` — pins
  watchdog/marker semantics around this area (#339; cited by FI-OC-015).
  Read-only; if it fails, your change is wrong.
- The primary pins for this file live outside `regression/`:
  `src/test/aiur/opencode/chat_completions_test.exs` (480 lines of pure-helper
  pins that move with their functions), `src/test/aiur/opencode/bridge_test.exs`
  (end-to-end 401/400/placeholder routing — must pass unmodified), and
  `src/test/aiur/claude/transcript_test.exs` (diff-fence integration).

## Acceptance criteria

- All 9 lib files under Create exist; `src/lib/aiur/opencode/chat_completions.ex`
  still exists (slimmed).
- Line caps (`grep -c "" <file>`): every new lib file <= 200 lines, EXCEPT
  `turn_stream.ex` <= 240 and `delta_renderer.ex` <= 220 (verbatim-moved race
  documentation dominates; the research doc sizes them ~220/~200 with docs).
  `chat_completions.ex` <= 200 lines.
- No new function exceeds 20 logic lines; verbatim-MOVED functions keep their
  existing shape (splitting `codex_turn_stream_loop/6` or any other moved
  function is forbidden — this is a relocation, not a rewrite).
- `grep -c "@moduledoc" <each new lib file>` >= 1 and it is not
  `@moduledoc false`.
- Every public `def` in each new lib file has a `@spec` (reviewer-verified;
  `mix dialyzer` passes).
- `grep -rn "defdelegate" src/lib/aiur/opencode/` → no matches.
- Each new lib module has its matching test file from the Create list with
  >= 1 test (`grep -c "test " <file>` >= 1); new modules are NOT
  coverage-exempt.
- `git diff --name-only origin/v2...HEAD` does NOT contain
  `src/lib/aiur/opencode/protocol.ex`, `src/lib/aiur/opencode/bridge.ex`,
  `src/mix.exs`, or anything under `src/test/aiur/regression/`.
- `grep -F '@operator_wrapper_regex' src/lib/aiur/opencode/operator_text.ex`
  matches, and the regex line is byte-identical to the original
  (chat_completions.ex:818 pre-move).
- `grep -F '__aiur_turn__:' src/lib/aiur/opencode/chat_completions.ex` still
  matches (marker literals kept for binary-prefix matching).
- `grep -n "normalize_operator_text\|operator_text_trace\|scan_operator_messages" src/lib/aiur/opencode/chat_completions.ex`
  → no matches (moved, not duplicated).
- `grep -F 'def finish_reason_for(_reason), do: "stop"' src/lib/aiur/opencode/chat_completions/sse.ex`
  matches (busy-loop guard intact).
- `grep -F "Aiur.Opencode.ChatCompletions.DeltaRenderer" src/test/aiur/claude/transcript_test.exs`
  matches.
- `grep -rn "Task\.\|GenServer\|spawn" src/lib/aiur/opencode/chat_completions/ src/lib/aiur/opencode/operator_text.ex`
  → no matches (request-process affinity preserved).
- Full suite green: `mix test` passes with zero failures and zero skips;
  every wave's commit also compiled and passed in sequence.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- Check (FI-OC-010): restart Aiur while a pane holds an old session — replayed
  `__aiur_turn__` markers close instantly with `"stop"`, no 10-minute ghost
  stream.
- Check (FI-OC-013/016): keep a chat pane open through a >60s quiet
  multi-segment turn — transcript events render exactly once (no duplicate
  rendering after ~30s, no stacked subscriptions in later segments).
- Check (FI-OC-017): drive a turn to `:input_required` — opencode does not
  busy-loop reopening completions; CPU stays flat.
- Check (FI-OC-026): type into a chat pane — the QUEUED indicator clears
  within ~1s and the agent's reply arrives later through the turn stream.
- Check (FI-OC-028): `grep "opencode_bridge operator_text"` in the session log
  shows the `in_bytes/out_bytes/wrapped/dropped` trace line unchanged.
- Spot-check the diff: every hunk in a new file corresponds to a deletion in
  `chat_completions.ex` (relocation, not rewrite); doc comments traveled with
  their functions.
- Confirm `git show <merge>:src/lib/aiur/opencode/protocol.ex` is byte-identical
  to its pre-merge content.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
