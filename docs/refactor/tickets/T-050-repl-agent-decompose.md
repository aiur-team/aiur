# T-050: repl_agent: Launcher, Command, RcAttach, Reaper, PromptSubmit, tailers; slim

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/claude/repl_agent.ex` (1,175 lines) is the persistent
interactive-REPL claude backend ("claude-repl"): tmux pane lifecycle, RC
attach, two prompt-submit protocols, two turn loops (hook-driven and
transcript-tailing), operator injection, and owner-pid-scoped pane reaping —
all in one module. Per the binding name map in
`docs/refactor/research-arch/giant-repl_agent.md` §2, this ticket splits it
into nine `Aiur.Claude.Repl.*` submodules under `src/lib/aiur/claude/repl/`,
behind the existing `Aiur.Claude.ReplAgent` facade. The facade name is
load-bearing: it is the `Aiur.CodingAgent` adapter for `"claude-repl"`
(`src/lib/aiur/coding_agent.ex:101`, pinned by
`src/test/aiur/coding_agent_test.exs:152`) and is called directly by
`src/lib/aiur/orchestrator.ex` (`interrupt/1`, `reap_orphaned_panes/0`) and
`src/lib/aiur/shutdown.ex:46` (`sweep_own_panes/0`). No external call site
changes.

This is a behavior-preserving, move-only, SINGLE-wave decomposition (one
ticket, one PR — follow the internal ordering in giant-repl_agent.md §3 for
your commits if you like, but everything below lands together). Move code
verbatim wherever possible — extract, do not rewrite. Public function
signatures and all observable behavior stay unchanged; the facade delegates
to the extracted modules so every existing caller and test keeps working.
Line ranges below cite `repl_agent.ex` as of the planning snapshot (branch
`refactor-planning-prompt`); function NAMES are authoritative, the ranges pin
which code is meant. Comments move with their functions (they carry the
why — the paste race, the reap-scoping history).

## Scope (exact)

1. **Create `src/lib/aiur/claude/repl/command.ex`** defining
   `Aiur.Claude.Repl.Command` — pure spawn-plan policy:
   - Move verbatim, made public with `@spec`: `build_command/7` (was
     1080–1092, with the `exec` comment at 1078–1079) and
     `maybe_hook_settings/2` (both clauses, was 1115–1138, with its
     comment) — `Launcher` calls both.
   - Move verbatim as public `@doc false` with its existing `@spec`:
     `resume_session_id/2` (was 1094–1113, with the full resume-policy
     comment). The facade keeps a `defdelegate` so the direct tests in
     `repl_agent_test.exs` (`describe "resume_session_id/2"`) stay green
     unchanged.
   - Move verbatim as private: `append_if/3` (was 1140–1142) and
     `shell_escape/1` (was 1172–1174).
   - `@moduledoc` stating this module owns the `exec claude` command line,
     the `--resume` policy, and the RC hook `--settings` wiring; `@spec` on
     every public def.

2. **Create `src/lib/aiur/claude/repl/rc_attach.ex`** defining
   `Aiur.Claude.Repl.RcAttach` — RC attach evidence and URL harvest:
   - Move the module attributes `@url_capture_timeout_ms 10_000` and
     `@url_poll_ms 150` (was 77–87, with the full banner/capability-token
     comment block) and `@rc_dialog_timeout_ms 5_000` (was 294–297, with its
     comment).
   - Move verbatim, made public with `@spec`: `capture_session_url/3` (was
     247–269, with both comment blocks) — `Launcher` calls it; `nil` remains
     the RC-unavailable signal.
   - Move verbatim as private: `poll_rc_evidence/3` (was 271–292),
     `harvest_url_via_rc_command/2` (was 298–310), `do_capture_session_url/3`
     (was 312–330).
   - Preserve verbatim: the `/rc` harvest ALWAYS sends Esc — even when the
     dialog scrape fails or times out — so the dialog can't eat the first
     prompt's keystrokes (`_ = Tmux.send_escape(tmux, pane_id)` after the
     `with`, unconditionally).
   - `@moduledoc`; the session URL is a capability token — never logged.

3. **Create `src/lib/aiur/claude/repl/reaper.ex`** defining
   `Aiur.Claude.Repl.Reaper` — single source of truth for the
   owner-pid-encoded window-name scheme, teardown, and liveness:
   - Move `@repl_window_prefix "aiur-repl-"` (was 36–40, with its
     owner-pid-scoping comment).
   - Move verbatim, made public with `@spec` (and their existing `@doc`
     strings where present): `stop_session/1` (BOTH clauses, was 332–356 —
     unregister both reaper keys → kill pane → `graceful_kill_tree` →
     pane_gone/pid_gone verification → teardown perf event, in exactly this
     order), `reap_orphaned_panes/1` (was 358–369, `tmux \\ Tmux` default
     kept), `sweep_own_panes/1` (was 371–383, default kept),
     `default_repl_name/0` (was 420 — `Launcher` calls it), and
     `pane_alive?/1` (was 984–986 — both turn loops call it).
   - Move verbatim as private: `sweep_repl_panes/2` (was 385–397, including
     the `:ok` on `list_windows` error), `maybe_kill_repl_pane/4` (was
     399–406), `kill_orphan_pane/2` (was 408–418), `beam_os_pid/0` (was 422),
     `parse_owner_pid/1` (was 424–430, with the format comment),
     `os_pid_alive?/1` (was 432–436, keep the `rescue`), `os_pid_gone?/1`
     (both clauses, was 438–444, keep the `rescue`).
   - Preserve verbatim (giant-repl_agent.md §4 risk 9): boot reap kills ONLY
     panes whose embedded owner BEAM pid is dead; shutdown sweep kills ONLY
     panes whose owner pid equals this BEAM's pid; a side-by-side aiur
     instance's live panes are never touched.
   - `@moduledoc` naming the window-name scheme
     `aiur-repl-<beam_os_pid>-<n>` as this module's owned fact.

4. **Create `src/lib/aiur/claude/repl/turn_events.ex`** defining
   `Aiur.Claude.Repl.TurnEvents` — the one home for the `on_message`
   envelope shape:
   - Move verbatim, made public with `@spec`: `emit/3` and
     `emit_transcript/2` (was 1004–1010). Both turn-loop modules call these.
   - `@moduledoc` stating the envelope shapes
     (`%{event:, timestamp:, …}` and
     `%{event: :transcript, transcript_event:, timestamp:}`) are consumed by
     the runner and mirrored by `Aiur.Claude.DisplayTailer` — do not alter a
     single key.

5. **Create `src/lib/aiur/claude/repl/prompt_submit.ex`** defining
   `Aiur.Claude.Repl.PromptSubmit` — BOTH prompt-delivery protocols, side by
   side, NEVER unified (giant-repl_agent.md §4 risk 1; MEMORY "RC prompt
   submit paste race"; #373/#374):
   - Move `@echo_confirm_ms 20_000`, `@echo_retype_ms 1_500`,
     `@echo_poll_ms 100` (was 59–69, with the full dropped-first-paste
     comment) and `@paste_indicator "[Pasted text"` (was 71–75, with its
     comment).
   - Public `submit(session, prompt, opts) :: :ok | {:error, term()}` —
     verbatim body of `submit_prompt/3` (was 742–747) with its complete
     comment block (was 733–741). Hook/RC protocol: paste → wait read-only
     for the paste to land → Enter. It NEVER clears/retypes (`C-u` reads as
     an interrupt cancelling a live RC turn) and never fails on echo
     timeout — Enter still fires best-effort and the UserPromptSubmit hook
     confirms receipt.
   - Public `send(session, prompt, opts) :: :ok | {:error, term()}` —
     verbatim body of `send_prompt/3` (was 777–782) with its comment.
     Transcript protocol: confirm the echo (clear + re-paste retry on
     `@echo_retype_ms`) before Enter; fail loudly with
     `{:error, :prompt_not_delivered}` rather than ever submitting a blank
     line.
   - Move verbatim as private: `await_paste_landed/3` (was 754–759, with the
     read-only comment at 749–753), `poll_paste_landed/3` (was 761–773),
     `confirm_typed/3` (was 791–798, with its comment at 784–790),
     `poll_echo/8` (was 800–823, with the retype comment),
     `input_echoes?/2` (was 825–834), `echo_prefix/1` (was 836–838).
   - The ONLY call to `Tmux.clear_input/2` in this module is inside
     `poll_echo/8`; `submit/3` and everything it calls must contain none.
   - `@moduledoc` MUST state, verbatim from the risk section: the two
     protocols are deliberately different and must never be DRY-merged —
     merging reintroduces the #373/#374 paste race and the respawn loop.
   - `@spec` on both public defs.

6. **Create `src/lib/aiur/claude/repl/operator_inject.ex`** defining
   `Aiur.Claude.Repl.OperatorInject` — operator input into the live pane:
   - Move verbatim, made public, keeping their existing `@doc` + `@spec`:
     `send_operator_message/2` (BOTH clauses, was 1012–1043) and
     `interrupt/1` (BOTH clauses, was 1045–1062, including the
     minimal-`%{tmux:, pane_id:}`-map comment — the orchestrator builds that
     shape).
   - Move verbatim, made public with `@spec`:
     `deliver_immediate_operator_message/2` (was 961–982, with the claim
     callback comment at 957–960) — BOTH turn loops call it.
   - Move verbatim as private: `sanitize_pane_input/1` (was 1069–1074, with
     the security comment at 1064–1068). Preserve exactly: every control
     byte (`\x00-\x1f`, `\x7f`) collapses to a space, space runs collapse,
     trim; the single trailing Enter is the only submit; `""` after
     sanitize returns `{:error, :empty_message}` with no keys sent.
   - `@moduledoc`; `@spec` on the three public defs.

7. **Create `src/lib/aiur/claude/repl/hook_turn.ex`** defining
   `Aiur.Claude.Repl.HookTurn` — the hook-driven (RC) turn loop:
   - Public `run(session, prompt, opts)` — verbatim body of
     `drive_turn_via_hooks/3` (was 503–541) with its comment block (was
     496–502), rewiring internal calls only: `submit_prompt(…)` →
     `PromptSubmit.submit(…)`, `emit(…)` → `TurnEvents.emit(…)`.
   - Move verbatim as private: `await_hook_turn/3` (was 545–601, with every
     branch comment — rewire `pane_alive?` → `Reaper.pane_alive?`,
     `deliver_immediate_operator_message` →
     `OperatorInject.deliver_immediate_operator_message`, `interrupt` →
     `OperatorInject.interrupt`), `reset_deadline/1` and `merge_session/2`
     (was 603–606), `finish_hook_turn/2` (all 3 clauses, was 608–631, with
     the thread_id comment — rewire `emit` → `TurnEvents.emit`).
   - Define locally `@turn_poll_ms 250` and `@pause_confirm_ms 10_000` with
     a one-line comment noting the values are shared with `TranscriptTurn`
     (the constants are deliberately duplicated in both loop modules to keep
     the dependency graph one-way; do not create a shared constants module).
   - Preserve verbatim (risks 2, 3, 4, 7, 8): the loop runs in the
     `run_turn` caller process as a plain function call — no Task, no
     GenServer (`{:pause_agent, id}` and `{:agent_queue_updated, …}` are
     sent to that process); every `{:claude_hook, …}` resets the backstop
     deadline but `{:agent_queue_updated, …}` deliberately does NOT; pause
     always parks as `{:paused, %{request_id: request_id}}` even when
     `interrupt` errors; `finish_hook_turn` returns the RAW hook-reported
     session id as `thread_id` (nil if the hook never carried one), never
     the synthetic `repl-…` display fallback; `HookEvents.subscribe/1` /
     `unsubscribe/1` stay in `try`/`after`.
   - `@moduledoc` (state the caller-process requirement); `@spec` on
     `run/3`.

8. **Create `src/lib/aiur/claude/repl/transcript_turn.ex`** defining
   `Aiur.Claude.Repl.TranscriptTurn` — the transcript-tailing (non-RC) turn
   loop:
   - Move `@turn_poll_ms 250`, `@pause_confirm_ms 10_000` (was 42–51, with
     the park-not-error comment), `@transcript_wait_ms 15_000`,
     `@transcript_poll_ms 100` (was 53–57, with the cold-start comment).
   - Public `run(session, prompt, opts)` — verbatim body of
     `drive_turn_via_transcript/3` (was 633–674), rewiring internal calls
     only: `send_prompt(…)` → `PromptSubmit.send(…)`, `emit(…)` →
     `TurnEvents.emit(…)`.
   - Move verbatim as private: `finish_turn/5` (all 3 clauses, was 676–698,
     with the paused-payload comment), `prepare_turn/3` (was 710–721, with
     the WARM/COLD comment block at 700–709), `resolve_session_transcript/1`
     (was 725–731, with its since-comment), `await_transcript/1` and `/2`
     (was 841–860), `start_turn_tailer/4` (was 866–881, with the
     parent-routing comment at 862–865), `await_turn/7` (was 883–935, with
     every branch comment — rewire `pane_alive?` → `Reaper.pane_alive?`,
     operator/interrupt calls → `OperatorInject.*`),
     `await_pause_confirm/4` (was 940–955, with its comment),
     `stop_tailer/1` (was 988–993), `turn_ids/1` (was 995–1002, with its
     comment), and rewire `emit`/`emit_transcript` → `TurnEvents.*`.
   - Preserve verbatim (risks 2, 4, 5, 6): plain function call in the
     caller's process — `start_turn_tailer` captures `parent = self()`
     BEFORE `TranscriptTailer.start_link` so `{:turn_end, turn_id, reason}`
     routes back to the awaiting process; WARM tails `from: :end` and sends
     the prompt AFTER the tailer attaches, COLD sends the prompt first then
     tails `from: :start` (reordering either loses this turn's records or
     replays history — backfill stays display-only, the tailer never
     re-prompts the agent); the transcript deadline is fixed (no
     event-driven reset); the pause payload carries
     `session_id`/`thread_id`/`turn_id` (the runner reads them) and expiry
     of `await_pause_confirm` parks — never `{:error, :turn_timeout}`;
     `resolve_session_transcript` passes `since: session.started_at` so a
     reused workspace never tails a prior run's jsonl.
   - `@moduledoc` (state the caller-process and warm/cold ordering
     requirements); `@spec` on `run/3`.
   - This file may reach 240 lines (the §2 name map's documented exception:
     the cold/warm decision, tailer wiring, and await loop are one temporal
     protocol; splitting them would smear the ordering invariants).

9. **Create `src/lib/aiur/claude/repl/launcher.ex`** defining
   `Aiur.Claude.Repl.Launcher` — session spawn and readiness:
   - Move `@ready_prompt "❯"`, `@ready_poll_ms 200`,
     `@ready_timeout_ms 15_000` (was 32–34).
   - Public `start_session(workspace, opts)` — verbatim body of
     `start_session/2` (was 108–157, with the started_at, settings, and
     resume comments), rewiring internal calls only:
     `maybe_hook_settings(…)` → `Command.maybe_hook_settings(…)`,
     `resume_session_id(…)` → `Command.resume_session_id(…)`,
     `build_command(…)` → `Command.build_command(…)`,
     `default_repl_name()` → `Reaper.default_repl_name()`.
   - Move verbatim as private: `finish_start/2` (was 159–189 — keep BOTH
     `Aiur.ProcessReaper.register` calls, `{:pane, pane_id}` and
     `{:os_pid, os_pid}` with `comm: "claude"`, and the kill-pane on
     `:repl_not_ready`), `build_ready_session/3` (BOTH clauses, was
     191–217, with the RC-gate comment block — rewire
     `capture_session_url(…)` → `RcAttach.capture_session_url(…)`; keep the
     pane kill + `graceful_kill_tree` + perf event +
     `{:error, :remote_control_unavailable}` degrade exactly),
     `repl_session/4` (was 219–245, with the resumed/identifier comments),
     `await_ready/3`, `do_await_ready/3`, `retry_ready/3` (was 1144–1170).
   - `@moduledoc`; `@spec` on `start_session/2` (return type references
     `Aiur.Claude.ReplAgent.session()`).

10. **Slim `src/lib/aiur/claude/repl_agent.ex`** to the behaviour facade:
    - Keep byte-identical: the `@moduledoc`, `@behaviour Aiur.CodingAgent`,
      the `@type session` (was 89–105), the `run_turn/4` `@doc`/`@spec` and
      all three heads with the empty-prompt guards (was 452–486), and
      `normalize_event/1` (was 446–450).
    - `drive_turn/3` (was 488–494) stays as the private route, its two
      branches becoming `HookTurn.run(session, prompt, opts)` and
      `TranscriptTurn.run(session, prompt, opts)`.
    - Replace every other public entry point with a delegate to its new
      home, keeping today's `@doc`/`@spec` strings on the facade:
      `def start_session(workspace, opts \\ []) when is_binary(workspace),
      do: Launcher.start_session(workspace, opts)`;
      `defdelegate stop_session(session), to: Reaper`;
      `defdelegate reap_orphaned_panes(tmux \\ Tmux), to: Reaper`;
      `defdelegate sweep_own_panes(tmux \\ Tmux), to: Reaper`;
      `defdelegate send_operator_message(session, payload), to: OperatorInject`;
      `defdelegate interrupt(session), to: OperatorInject`;
      `@doc false` + `defdelegate resume_session_id(opts, workspace),
      to: Command`.
    - Add `alias Aiur.Claude.Repl.{Command, HookTurn, Launcher,
      OperatorInject, Reaper, TranscriptTurn}`; delete every moved function,
      every moved module attribute, and every now-unused alias.
    - Slimmed ceiling: `repl_agent.ex` must be ≤ 250 lines after the wave.

11. **Create the nine test files** under `src/test/aiur/claude/repl/` (new
    modules are NOT coverage-exempt — do not touch `ignore_modules` in
    `src/mix.exs`). Where a tmux is needed, reuse the exact mock pattern
    from `repl_agent_test.exs`: `async: false`,
    `start_supervised({Tmux, [transport: {:mock, test_pid}, name: name,
    session: "test"]})` plus the `respond/2` / `respond_error/2` helpers
    framing `%begin/%end/%error`. Call the NEW modules directly (the facade
    paths are already pinned by `repl_agent_test.exs`):
    - `command_test.exs`: `build_command/7` flag order
      (`--remote-control` → `--resume` → `--permission-mode` (always) →
      `--model` → `--effort` → `--settings`), single-quote shell escaping of
      a value containing `'`, and `cd <ws> && exec claude` shape;
      `resume_session_id/2` returns the id only when the jsonl exists,
      else nil (blank/missing handle → nil); `maybe_hook_settings/2`
      returns nil for non-RC, nil for RC without a binary identifier, and
      nil (no raise) when `HookSettings.dashboard_url/0` is nil — the
      no-dashboard degrade path.
    - `rc_attach_test.exs`: banner form returns the URL; footer form
      (`/rc active`) types `/rc`, Enter, scrapes the dialog URL, then sends
      Esc; scrape timeout still sends Esc and returns nil (the
      always-dismiss invariant); no evidence within the budget returns nil.
    - `reaper_test.exs`: `parse_owner_pid`-scoped sweeps —
      `reap_orphaned_panes/1` kills only dead-owner `aiur-repl-` windows;
      `sweep_own_panes/1` kills only this BEAM's own windows; a
      `list_windows` error returns `:ok` and kills nothing;
      `stop_session/1` unregisters, kills the pane, and returns `:ok` for
      an invalid session map; `pane_alive?/1` true/false on
      `pane_pid` success/error; `default_repl_name/0` matches
      `~r/^aiur-repl-\d+-\d+$/`.
    - `turn_events_test.exs`: `emit/3` merges `%{event:, timestamp:}` over
      the details map; `emit_transcript/2` wraps as
      `%{event: :transcript, transcript_event: event, timestamp: _}`.
    - `prompt_submit_test.exs`: `submit/3` pastes, polls read-only, sends
      Enter after the `[Pasted text` chip or 24-char prefix lands, and on
      echo timeout STILL sends Enter — asserting NO `clear_input` command
      ever reaches the mock tmux on this path (flunk on one); `send/3`
      re-pastes after a clear when the echo is missing and returns
      `{:error, :prompt_not_delivered}` on budget expiry with no Enter sent.
    - `operator_inject_test.exs`: control bytes collapse to spaces with one
      trailing Enter as the only submit; all-control-byte body →
      `{:error, :empty_message}`, no keys sent; non-text payload →
      `{:error, :invalid_message}`; `interrupt/1` on a minimal
      `%{tmux:, pane_id:}` map sends Ctrl+C; non-map/invalid →
      `{:error, :invalid_session}`;
      `deliver_immediate_operator_message/2` fires `on_success` with a
      request id on delivery, `on_failure` on a send error, and returns
      `:ok` on `:noop`.
    - `hook_turn_test.exs` (closes the §4 characterization gaps): a
      `{:pause_agent, request_id}` message into the running loop returns
      `{:paused, %{request_id: ^request_id}}` after sending Ctrl+C; a fully
      silent session (no hook events) returns `{:error, :turn_timeout}`
      only after the backstop, and a `post_tool_use` hook event resets that
      deadline (loop survives past the original deadline); Stop with a
      session id returns `thread_id` == that raw id; Stop with no session
      id returns `thread_id == nil` while `session_id` falls back to
      `repl-<n>`.
    - `transcript_turn_test.exs`: cold start where the jsonl never
      materializes returns `{:error, :no_transcript}` (gap closure); warm
      turn tails `from: :end` and completes on `{:turn_end, …}` with
      `{:ok, %{result: :completed, session_id:, thread_id:, turn_id:}}`;
      `{:pause_agent, id}` parks as `{:paused, payload}` with
      `session_id`/`thread_id`/`turn_id` present even when the
      pause-confirm window expires.
    - `launcher_test.exs`: readiness timeout kills the pane and returns
      `{:error, :repl_not_ready}`; a ready non-RC spawn returns the session
      map with `backend: "claude-repl"` and registers both ProcessReaper
      keys; an RC spawn with no attach evidence kills the pane and returns
      `{:error, :remote_control_unavailable}`.

12. Do NOT edit `src/test/aiur/claude/repl_agent_test.exs` — it drives the
    facade's public API and is this refactor's primary safety net; it must
    pass unchanged.

13. From `src/`: `mix format`, then the full Agent gate below. The repo
    compiles and the full suite passes at the end of this wave.

## Files

- Create: `src/lib/aiur/claude/repl/command.ex`,
  `src/lib/aiur/claude/repl/rc_attach.ex`,
  `src/lib/aiur/claude/repl/reaper.ex`,
  `src/lib/aiur/claude/repl/turn_events.ex`,
  `src/lib/aiur/claude/repl/prompt_submit.ex`,
  `src/lib/aiur/claude/repl/operator_inject.ex`,
  `src/lib/aiur/claude/repl/hook_turn.ex`,
  `src/lib/aiur/claude/repl/transcript_turn.ex`,
  `src/lib/aiur/claude/repl/launcher.ex`
- Modify: `src/lib/aiur/claude/repl_agent.ex`
- Test: `src/test/aiur/claude/repl/command_test.exs`,
  `src/test/aiur/claude/repl/rc_attach_test.exs`,
  `src/test/aiur/claude/repl/reaper_test.exs`,
  `src/test/aiur/claude/repl/turn_events_test.exs`,
  `src/test/aiur/claude/repl/prompt_submit_test.exs`,
  `src/test/aiur/claude/repl/operator_inject_test.exs`,
  `src/test/aiur/claude/repl/hook_turn_test.exs`,
  `src/test/aiur/claude/repl/transcript_turn_test.exs`,
  `src/test/aiur/claude/repl/launcher_test.exs`

## Out of scope

- `src/lib/aiur/claude/coding_agent.ex`, `remote_control.ex`,
  `transcript_tailer.ex`, `transcript.ex`, `display_tailer.ex`,
  `hook_events.ex`, `hook_settings.ex`, `config.ex` — call them, do not
  edit them.
- `src/lib/aiur/tmux.ex` (T-053 owns it), `src/lib/aiur/orchestrator.ex`
  (T-022–T-027), `src/lib/aiur/shutdown.ex`, `src/lib/aiur/agent_runner.ex`
  (T-034–T-036), `src/lib/aiur/coding_agent.ex` — the `"claude-repl"` →
  `Aiur.Claude.ReplAgent` adapter mapping must not change.
- DRY-merging or "unifying" the two prompt-submit protocols — forbidden
  (risk 1; it reintroduces the #373/#374 paste race).
- Wrapping either turn loop in a Task, GenServer, or any new process —
  forbidden (risk 2; it silently breaks pause and mid-turn operator
  delivery).
- Renaming the facade, changing any public signature, altering any log
  line, perf-event name/field, or `on_message` envelope key.
- `src/test/aiur/claude/repl_agent_test.exs` — read-only.
- `src/mix.exs` — especially the coverage `ignore_modules` list: it only
  ever shrinks; adding any new module to it is forbidden.
- Everything under `src/test/aiur/regression/` — read-only.
- The characterization gaps NOT covered by step 11 (e.g. `stop_session`
  with a live os_pid engaging `graceful_kill_tree`) — do not chase them
  beyond the listed tests.

## Inventory-IDs

From `docs/refactor/feature-inventory/cld.md` — features implemented or
touched by `repl_agent.ex`; all must behave identically after the move:

- FI-CLD-014 — normalize_event delegation to the headless backend (facade)
- FI-CLD-016 — claude.model nil omits the model flag (Launcher/Command)
- FI-CLD-017 — permission_mode always passed as `--permission-mode` (Command)
- FI-CLD-021 — nil dashboard URL skips hook injection, never fails spawn
  (Command)
- FI-CLD-026 — REPL pane spawn, flag order, shell escaping
  (Launcher/Command)
- FI-CLD-027 — readiness wait on the `❯` glyph; timeout kills the pane
  (Launcher)
- FI-CLD-028 — RC attach gate, `/rc` harvest + always-Esc, degrade to
  `:remote_control_unavailable` (RcAttach/Launcher)
- FI-CLD-029 — `--resume` across restart; vanished transcript degrades to
  clean start (Command)
- FI-CLD-030 — best-effort hook-settings injection routes turn detection
  (Command/Launcher/facade)
- FI-CLD-031 — ProcessReaper double registration pane + pid
  (Launcher/Reaper)
- FI-CLD-032 — always-on repl perf events (Launcher/Reaper)
- FI-CLD-033 — stop_session teardown order and verification (Reaper)
- FI-CLD-034 — boot reap of orphaned panes, owner-pid scoped (Reaper)
- FI-CLD-035 — graceful-shutdown sweep of own panes only (Reaper)
- FI-CLD-036 — session reuse across turns, no respawn
  (facade/TranscriptTurn)
- FI-CLD-037 — run_turn routing hooks vs transcript, empty-prompt guard
  (facade)
- FI-CLD-038 — hook turn loop with event-reset backstop (HookTurn)
- FI-CLD-039 — hook-turn resume-handle hygiene (raw session id only)
  (HookTurn)
- FI-CLD-040 — hook-path submit: paste-then-wait, never clear
  (PromptSubmit)
- FI-CLD-041 — non-hook delivery: clear+re-paste, `:prompt_not_delivered`
  (PromptSubmit)
- FI-CLD-042 — warm/cold tail strategy, display-only backfill
  (TranscriptTurn)
- FI-CLD-043 — stale-transcript exclusion via `since: started_at`
  (TranscriptTurn)
- FI-CLD-044 — transcript-turn await loop and result shape
  (TranscriptTurn/TurnEvents)
- FI-CLD-045 — mid-turn operator message via native queue
  (OperatorInject/both loops)
- FI-CLD-046 — PTY input sanitization security property (OperatorInject)
- FI-CLD-047 — pause always parks, never errors (both loops)
- FI-CLD-048 — interrupt/1 accepts minimal `%{tmux:, pane_id:}` maps
  (OperatorInject)
- FI-CLD-056 — pre-extracted transcript_event envelope passthrough
  (TurnEvents)

## Characterization-tests

None under `src/test/aiur/regression/` — no regression file exercises the
claude-repl backend (grep hits for "repl" there are `String.replace` false
positives). The load-bearing protection is
`src/test/aiur/claude/repl_agent_test.exs` (1,314 lines, `async: false`,
mock control-mode tmux): it pins nearly every flow through the facade's
public API — spawn/ready/resume/RC-attach and degrade, teardown, both
sweeps' scoping, both turn loops, both submit protocols, operator inject,
sanitization, all pause outcomes, and `interrupt`. It must pass with ZERO
edits, plus `src/test/aiur/coding_agent_test.exs:152` pinning the
`"claude-repl"` adapter name.

## Acceptance criteria

- The nine new lib files exist under `src/lib/aiur/claude/repl/`; each is
  ≤ 200 lines (`grep -c "" <file>`) EXCEPT `transcript_turn.ex`, which is
  ≤ 240 (the name map's documented exception). All functions ≤ 20 logic
  lines.
- `grep -c "" src/lib/aiur/claude/repl_agent.ex` ≤ 250; the facade contains
  `@behaviour Aiur.CodingAgent`, the `@type session`, the three `run_turn`
  heads, `drive_turn`, `normalize_event`, and delegates only.
- Module names match the name map exactly:
  `grep -rn "^defmodule Aiur.Claude.Repl" src/lib/aiur/claude/repl/` yields
  exactly `Aiur.Claude.Repl.{Launcher, Command, RcAttach, Reaper,
  PromptSubmit, OperatorInject, TurnEvents, HookTurn, TranscriptTurn}`, one
  per file.
- Moved code is gone from the facade:
  `grep -n "defp build_command\|defp maybe_hook_settings\|defp capture_session_url\|defp poll_rc_evidence\|defp sweep_repl_panes\|defp parse_owner_pid\|defp submit_prompt\|defp confirm_typed\|defp poll_echo\|defp await_hook_turn\|defp await_turn\|defp start_turn_tailer\|defp sanitize_pane_input\|defp await_ready\|defp repl_session\|defp finish_start" src/lib/aiur/claude/repl_agent.ex`
  prints nothing.
- Every new file has a `@moduledoc`
  (`grep -L "@moduledoc" src/lib/aiur/claude/repl/*.ex` prints nothing) and
  `@spec` on every public `def`.
- Both submit protocols intact and separate:
  `grep -c "clear_input" src/lib/aiur/claude/repl/prompt_submit.ex` == 1
  (only the `poll_echo` retype branch);
  `grep -F ":prompt_not_delivered" src/lib/aiur/claude/repl/prompt_submit.ex`
  matches; `grep -rn "clear_input" src/lib/aiur/claude/repl/hook_turn.ex`
  prints nothing.
- No new processes in the loops:
  `grep -n "Task\.\|use GenServer\|spawn(" src/lib/aiur/claude/repl/hook_turn.ex src/lib/aiur/claude/repl/transcript_turn.ex`
  prints nothing except the pre-existing `TranscriptTailer.start_link` /
  `GenServer.stop` lines in `transcript_turn.ex`.
- Reap scoping intact:
  `grep -F "aiur-repl-" src/lib/aiur/claude/repl/reaper.ex` matches and
  `grep -rF "aiur-repl-" src/lib/aiur/claude/repl_agent.ex` prints nothing
  (one home for the window-name fact).
- `try` / `after` still wraps hook subscription:
  `grep -A2 "HookEvents.subscribe" src/lib/aiur/claude/repl/hook_turn.ex`
  shows `try`, and `grep -F "HookEvents.unsubscribe" src/lib/aiur/claude/repl/hook_turn.ex`
  sits in the `after` block.
- The nine test files exist under `src/test/aiur/claude/repl/`, each with
  ≥ 1 `test` block; every extracted module is exercised (new modules are
  NOT coverage-exempt; `src/mix.exs` is unchanged).
- `git diff --name-only origin/v2...HEAD` lists ONLY the files in the Files
  section — in particular no `src/mix.exs`, no
  `src/test/aiur/claude/repl_agent_test.exs`, no `src/lib/aiur/coding_agent.ex`,
  and nothing under `src/test/aiur/regression/`.
- Full Agent gate passes (below).

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

- Check: `mix test test/aiur/claude/repl_agent_test.exs` passes with the
  file byte-identical to `origin/v2`
  (`git diff origin/v2..HEAD -- src/test/aiur/claude/repl_agent_test.exs`
  is empty) — the facade safety net survived untouched.
- Check: in a live `v2` session with a claude-repl (RC) agent, the first
  prompt submits on the first try — no respawn loop, and the session log
  shows no repeated `repl_agent_spawn` for the same identifier
  (FI-CLD-040 probe).
- Check: pause a mid-turn claude-repl agent from the TUI — it parks as
  paused (⏸️, no failed-turn booking) and resumes cleanly (FI-CLD-047
  probe).
- Check: after a graceful aiur shutdown, `tmux list-windows -a` shows no
  `aiur-repl-` windows owned by the exited instance; with a second aiur
  instance running side by side, its live `aiur-repl-` windows survive the
  first instance's boot reap (FI-CLD-034/035 probe).
- Check: `git log --oneline origin/v2..HEAD -- src/test/aiur/regression/`
  is empty.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
