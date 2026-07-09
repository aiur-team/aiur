# Decomposition proposal: `src/lib/aiur/claude/repl_agent.ex` (1175 lines)

Behavior-preserving split of the claude-repl driver (tmux REPL lifecycle, prompt submit
paste race, transcript tailing) into `Aiur.Claude.Repl.*` submodules behind the existing
`Aiur.Claude.ReplAgent` facade. The facade name is load-bearing: it is the
`Aiur.CodingAgent` adapter for `"claude-repl"` (`src/lib/aiur/coding_agent.ex:101`,
pinned by `src/test/aiur/coding_agent_test.exs:152`), and it is called directly by
`orchestrator.ex` (`interrupt/1` at 6062/6132, `reap_orphaned_panes/0` at 6736) and
`shutdown.ex:46` (`sweep_own_panes/0`). All new modules are internal; no external call
site changes.

---

## 1. Function / responsibility census

Line numbers refer to the current file. "Logic lines" excludes comments/blank.

### A. Constants, type, behaviour glue (lines 1–106, 446–450)
| Function / item | Lines | ~Size |
|---|---|---|
| moduledoc, `@behaviour`, aliases | 1–30 | — |
| timing/window constants (`@ready_*`, `@repl_window_prefix`, `@turn_poll_ms`, `@pause_confirm_ms`, `@transcript_*`, `@echo_*`, `@paste_indicator`, `@url_*`) | 32–87 | ~20 |
| `@type session` | 89–105 | 17 |
| `normalize_event/1` (delegates to `Aiur.Claude.CodingAgent`) | 446–450 | 3 |

### B. Session spawn & readiness (lifecycle "up" path)
| Function | Lines | ~Logic lines |
|---|---|---|
| `start_session/2` (public, behaviour) | 107–157 | 40 |
| `finish_start/2` (ready gate, reaper registration) | 159–189 | 24 |
| `build_ready_session/3` ×2 (RC-attach gate / non-RC) | 191–217 | 16 |
| `repl_session/4` (session map assembly) | 219–245 | 24 |
| `await_ready/3`, `do_await_ready/3`, `retry_ready/3` | 1144–1170 | 22 |

### C. Spawn command construction & resume policy (pure-ish)
| Function | Lines | ~Logic lines |
|---|---|---|
| `build_command/7` (CLI flags, `exec claude`) | 1076–1092 | 13 |
| `resume_session_id/2` (public `@doc false`, directly tested) | 1094–1113 | 10 |
| `maybe_hook_settings/2` (writes `--settings` file for RC hooks) | 1115–1138 | 18 |
| `append_if/3`, `shell_escape/1` | 1140–1142, 1172–1174 | 5 |

### D. Remote Control attach evidence / URL harvest
| Function | Lines | ~Logic lines |
|---|---|---|
| `capture_session_url/3` | 247–269 | 9 |
| `poll_rc_evidence/3` | 271–292 | 18 |
| `harvest_url_via_rc_command/2` (+ `@rc_dialog_timeout_ms`) | 294–310 | 12 |
| `do_capture_session_url/3` | 312–330 | 15 |

### E. Teardown, sweeps, liveness probes, window-name scheme
| Function | Lines | ~Logic lines |
|---|---|---|
| `stop_session/1` ×2 (public, behaviour) | 332–356 | 20 |
| `reap_orphaned_panes/1` (public, boot) | 358–369 | 3 |
| `sweep_own_panes/1` (public, shutdown) | 371–383 | 4 |
| `sweep_repl_panes/2`, `maybe_kill_repl_pane/4`, `kill_orphan_pane/2` | 385–418 | 27 |
| `default_repl_name/0`, `beam_os_pid/0`, `parse_owner_pid/1` | 420–430 | 8 |
| `os_pid_alive?/1`, `os_pid_gone?/1` | 432–444 | 10 |

### F. Turn dispatch (hook vs transcript route)
| Function | Lines | ~Logic lines |
|---|---|---|
| `run_turn/4` heads (empty-prompt guards) | 452–486 | 10 |
| `drive_turn/3` (route on `session.identifier`) | 488–494 | 6 |

### G. Hook-driven turn loop (RC path)
| Function | Lines | ~Logic lines |
|---|---|---|
| `drive_turn_via_hooks/3` (subscribe/try/after, loop setup) | 496–541 | 32 |
| `await_hook_turn/3` (receive loop: Stop/PostToolUse/queue/pause) | 543–601 | 42 |
| `reset_deadline/1`, `merge_session/2` | 603–606 | 4 |
| `finish_hook_turn/2` ×3 (result shaping, thread_id rule) | 608–631 | 14 |

### H. Transcript-driven turn loop (non-RC path)
| Function | Lines | ~Logic lines |
|---|---|---|
| `drive_turn_via_transcript/3` (cold/warm orchestration) | 633–674 | 33 |
| `finish_turn/5` ×3 (result/pause payload shaping) | 676–698 | 16 |
| `prepare_turn/3` (warm `:end` vs cold `:start` decision) | 700–721 | 10 |
| `resolve_session_transcript/1` (since: started_at gate) | 723–731 | 6 |
| `await_transcript/1,2` (cold-start jsonl materialize poll) | 840–860 | 15 |
| `start_turn_tailer/4` (tailer wiring, parent-process routing) | 862–881 | 14 |
| `await_turn/7` (receive loop: turn_end/queue/pause) | 883–935 | 40 |
| `await_pause_confirm/4` | 937–955 | 14 |
| `stop_tailer/1`, `turn_ids/1` | 988–1002 | 10 |

### I. Prompt submission (the paste race — two distinct protocols)
| Function | Lines | ~Logic lines |
|---|---|---|
| `submit_prompt/3` (hook/RC variant: read-only wait, best-effort Enter, NEVER clears) | 733–747 | 6 |
| `await_paste_landed/3`, `poll_paste_landed/3` | 749–773 | 16 |
| `send_prompt/3` (transcript variant: fail-loud) | 775–782 | 6 |
| `confirm_typed/3`, `poll_echo/8` (clear + re-paste retry, `:prompt_not_delivered`) | 784–823 | 26 |
| `input_echoes?/2`, `echo_prefix/1` | 825–838 | 11 |

### J. Operator injection & interrupt (public parity actions)
| Function | Lines | ~Logic lines |
|---|---|---|
| `deliver_immediate_operator_message/2` (claim/deliver glue, used by BOTH loops) | 957–982 | 17 |
| `send_operator_message/2` ×2 (public, behaviour) | 1012–1043 | 15 |
| `interrupt/1` ×2 (public; orchestrator builds minimal `%{tmux:, pane_id:}`) | 1045–1062 | 6 |
| `sanitize_pane_input/1` (control-byte collapse, security-relevant) | 1064–1074 | 6 |

### K. Shared turn plumbing
| Function | Lines | ~Logic lines |
|---|---|---|
| `pane_alive?/1` | 984–986 | 3 |
| `emit/3`, `emit_transcript/2` (on_message envelope shape) | 1004–1010 | 6 |

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

Namespace: new `Aiur.Claude.Repl.*` sub-namespace under `src/lib/aiur/claude/repl/`
(mirrors how `Aiur.Opencode.*` splits one backend into per-concern files). Facade stays
at its current name/path. Dependency direction is strictly downward:

```
Aiur.Claude.ReplAgent  (facade, behaviour impl)
  ├─> Aiur.Claude.Repl.Launcher ──> Repl.Command, Repl.RcAttach, Repl.Reaper (window name)
  ├─> Aiur.Claude.Repl.HookTurn ──┐
  ├─> Aiur.Claude.Repl.TranscriptTurn ├─> Repl.PromptSubmit, Repl.OperatorInject,
  ├─> Aiur.Claude.Repl.OperatorInject │   Repl.TurnEvents, Repl.Reaper (pane_alive?)
  └─> Aiur.Claude.Repl.Reaper ────────┘
(all leaves ──> Aiur.Tmux / Aiur.Claude.{RemoteControl,HookEvents,HookSettings,TranscriptTailer})
```

| # | Module | File (under `src/lib/`) | Responsibility (one sentence) | ~LOC | Key functions that move there |
|---|---|---|---|---:|---|
| 1 | `Aiur.Claude.ReplAgent` | `aiur/claude/repl_agent.ex` (existing, shrinks) | Thin `Aiur.CodingAgent` behaviour facade: `session` type, empty-prompt guards, hook-vs-transcript route, and `defdelegate`s for every public entry point (`start_session`, `stop_session`, `run_turn`, `normalize_event`, `send_operator_message`, `interrupt`, `reap_orphaned_panes`, `sweep_own_panes`, `resume_session_id`). | 110 | `run_turn/4` heads, `drive_turn/3` route, `normalize_event/1`, delegations |
| 2 | `Aiur.Claude.Repl.Launcher` | `aiur/claude/repl/launcher.ex` | Spawn the hidden tmux REPL pane, await the ready glyph, run the RC-attach gate, register with the ProcessReaper, and assemble the session map. | 180 | `start_session/2` body, `finish_start/2`, `build_ready_session/3`, `repl_session/4`, `await_ready/3` + `do_await_ready/3` + `retry_ready/3`; `@ready_*` constants |
| 3 | `Aiur.Claude.Repl.Command` | `aiur/claude/repl/command.ex` | Pure spawn-plan policy: build the `exec claude` command line (flags, shell escaping), resolve the `--resume` session id against on-disk transcripts, and wire the RC lifecycle-hook `--settings` file. | 90 | `build_command/7`, `resume_session_id/2`, `maybe_hook_settings/2`, `append_if/3`, `shell_escape/1` |
| 4 | `Aiur.Claude.Repl.RcAttach` | `aiur/claude/repl/rc_attach.ex` | Prove Remote Control actually attached and harvest the `claude.ai/code/session_…` URL — via the startup banner or the `/rc` dialog (always dismissed with Esc); `nil` is the RC-unavailable signal. | 90 | `capture_session_url/3`, `poll_rc_evidence/3`, `harvest_url_via_rc_command/2`, `do_capture_session_url/3`; `@url_*`, `@rc_dialog_timeout_ms` |
| 5 | `Aiur.Claude.Repl.Reaper` | `aiur/claude/repl/reaper.ex` | Single source of truth for the owner-pid-encoded window-name scheme plus all teardown and liveness probing: `stop_session`, boot orphan reap, shutdown self-sweep, `pane_alive?`/os-pid checks. | 150 | `stop_session/1`, `reap_orphaned_panes/1`, `sweep_own_panes/1`, `sweep_repl_panes/2`, `maybe_kill_repl_pane/4`, `kill_orphan_pane/2`, `default_repl_name/0`, `beam_os_pid/0`, `parse_owner_pid/1`, `os_pid_alive?/1`, `os_pid_gone?/1`, `pane_alive?/1`; `@repl_window_prefix` |
| 6 | `Aiur.Claude.Repl.PromptSubmit` | `aiur/claude/repl/prompt_submit.ex` | Deliver a prompt through the paste race, keeping the two deliberately different protocols side by side: `submit/3` (hook/RC: read-only land-wait, best-effort Enter, never clears) and `send/3` (transcript: clear+re-paste retry, fail-loud `:prompt_not_delivered`). | 130 | `submit_prompt/3`→`submit/3`, `await_paste_landed/3`, `poll_paste_landed/3`, `send_prompt/3`→`send/3`, `confirm_typed/3`, `poll_echo/8`, `input_echoes?/2`, `echo_prefix/1`; `@echo_*`, `@paste_indicator` |
| 7 | `Aiur.Claude.Repl.OperatorInject` | `aiur/claude/repl/operator_inject.ex` | Inject operator input into the live pane: control-byte sanitization + literal type + single Enter (`send_operator_message`), the Ctrl+C `interrupt`, and the mid-turn claim/deliver glue shared by both turn loops. | 90 | `send_operator_message/2`, `interrupt/1`, `sanitize_pane_input/1`, `deliver_immediate_operator_message/2` |
| 8 | `Aiur.Claude.Repl.TurnEvents` | `aiur/claude/repl/turn_events.ex` | Own the `on_message` event envelope shape (`%{event:, timestamp:, …}` for `:session_started` / `:turn_completed` / `:turn_paused` / `:turn_ended_with_error` / `:transcript`) consumed by the runner and mirrored by `DisplayTailer`. | 40 | `emit/3`, `emit_transcript/2` |
| 9 | `Aiur.Claude.Repl.HookTurn` | `aiur/claude/repl/hook_turn.ex` | Hook-driven turn loop (RC sessions): subscribe/unsubscribe to `HookEvents`, event-reset backstop deadline, Stop-completes-turn, mid-turn operator delivery and pause parking — running in the caller's process. | 150 | `drive_turn_via_hooks/3`→`run/3`, `await_hook_turn/3`, `reset_deadline/1`, `merge_session/2`, `finish_hook_turn/2` |
| 10 | `Aiur.Claude.Repl.TranscriptTurn` | `aiur/claude/repl/transcript_turn.ex` | Transcript-tailing turn loop (non-RC sessions): warm/cold transcript resolution and tailer ordering, `TranscriptTailer` lifecycle, await/pause-confirm receive loop, and thread/turn-id derivation — running in the caller's process. | 210 | `drive_turn_via_transcript/3`→`run/3`, `finish_turn/5`, `prepare_turn/3`, `resolve_session_transcript/1`, `await_transcript/1,2`, `start_turn_tailer/4`, `await_turn/7`, `await_pause_confirm/4`, `stop_tailer/1`, `turn_ids/1`; `@turn_poll_ms`, `@pause_confirm_ms`, `@transcript_*` |

Sum ≈ 1,240 LOC (comment-heavy file; the heavy why-comments move with their functions).
Only `TranscriptTurn` exceeds the 200-line guiding target (210, judgment call: the
cold/warm decision, the tailer wiring, and the await loop are one temporal protocol and
splitting them would smear the turn's ordering invariants across files).

House-style notes:
- **One source of truth per fact:** the window-name format (write `default_repl_name/0`
  + parse `parse_owner_pid/1`) lands in one module (`Reaper`); the on_message envelope
  shape lands in one module (`TurnEvents`); the paste-landed predicate
  (`input_echoes?` + `@paste_indicator`) lands in one module (`PromptSubmit`).
- **Pure policy functions:** `Command` is (near-)pure and directly unit-testable
  without the tmux mock; the route decision (`identifier` present ⇒ hook path) stays a
  pure function-head choice in the facade.
- **No fan-out / one dependency direction:** loops call leaves; nothing calls back up.
  No new processes, no GenServers — every extracted loop remains a plain function call
  in the `run_turn` caller process (this is a semantic requirement, see Risks).

---

## 3. Extraction sequencing

Strictly serialized waves on this file; after each wave `mix compile` is clean and the
full suite (`repl_agent_test.exs` untouched, driving the facade) passes. Lines-moved
counts include moved comments.

- **Wave 1 — leaves: `Repl.Command` + `Repl.RcAttach` (~200 lines moved).** Move
  command construction, resume-id policy, hook-settings wiring, and the RC URL-harvest
  cluster. Facade `defdelegate resume_session_id/2` keeps the direct test green.
  Lowest risk: no receive loops, no session-map changes.
- **Wave 2 — `Repl.Reaper` + `Repl.TurnEvents` (~190 lines moved).** Move teardown,
  sweeps, window naming, and liveness probes into `Reaper` (facade delegates
  `stop_session/1`, `reap_orphaned_panes/1`, `sweep_own_panes/1` — orchestrator and
  shutdown call sites unchanged); move `emit`/`emit_transcript` into `TurnEvents`.
- **Wave 3 — `Repl.PromptSubmit` + `Repl.OperatorInject` (~240 lines moved).** Move both
  submit protocols verbatim (do NOT unify them) and the operator inject/interrupt/
  sanitize cluster; facade delegates `send_operator_message/2` and `interrupt/1`.
- **Wave 4 — `Repl.Launcher` (~200 lines moved).** Move the `start_session` pipeline
  (spawn, ready-wait, RC gate via `RcAttach`, reaper registration, session assembly);
  facade `start_session/2` becomes a one-line delegate.
- **Wave 5 — `Repl.HookTurn` + `Repl.TranscriptTurn` (~380 lines moved).** Move the two
  turn loops; the facade keeps only the `run_turn` guards and the two-line route. This
  is the riskiest wave (receive loops, tailer wiring) and goes last, when everything it
  calls is already stable in its final home.

Each wave is a single reviewable ticket ≤400 lines moved; waves must not run
concurrently (every wave edits `repl_agent.ex`).

---

## 4. Risks: semantics to preserve verbatim

Hotspot context (`docs/refactor/research-history-hotspots.md`): this file sits in
hotspot row 8 (*Agent backends: Claude/RC — "RC prompt-delivery races (#373 paste,
#332)"*), and its teardown half sits in rows 12 (*reap scoping repeatedly wrong*) and 3
(*instance-identity collision chain #431→#443→#592*). Cross-cutting theme 1 (*timing
and submission races — "anything that sends-then-assumes needs an explicit ack"*) is
literally this module's paste-race machinery.

**Concurrency / timing invariants (verbatim-preserve):**

1. **Two submit protocols, never unified.** `submit_prompt` (hook/RC) waits read-only
   for the paste to land, never sends `C-u` (claude reads it as an interrupt that
   cancels a live turn), and Enters best-effort on timeout (a mid-turn fold clears the
   chip; the UserPromptSubmit hook confirms receipt). `send_prompt`/`confirm_typed`
   (transcript) clears + re-pastes on `@echo_retype_ms` and fails loudly with
   `:prompt_not_delivered` rather than submitting a blank line. DRY-merging these
   reintroduces the #373/#374 paste race and the respawn loop the MEMORY note "RC
   prompt submit paste race" documents. Tests pin both (incl. a `flunk` on any `C-u`
   in the hook path).
2. **Receive loops run in the `run_turn` caller process.** `{:pause_agent, id}` and
   `{:agent_queue_updated, …}` are sent by the orchestrator to that process, and
   `start_turn_tailer` captures `parent = self()` so `{:turn_end, turn_id, reason}`
   routes back to it. Extraction must keep the loops as plain function calls — wrapping
   them in a Task/GenServer silently breaks pause and mid-turn operator delivery.
3. **Deadline semantics differ by path and by message.** Hook path: every
   `{:claude_hook, …}` resets the backstop (`reset_deadline`), but queue-update
   messages deliberately do NOT; transcript path: fixed deadline. Preserve exactly.
4. **Pause always parks.** A failed `interrupt` send, a pause-confirm timeout, or an
   expiry all still return `{:paused, …}` — never `{:error, :turn_timeout}` (which
   would book a failed turn and re-dispatch). The transcript-path pause payload must
   carry `session_id`/`thread_id`/`turn_id` (the runner reads them).
5. **Cold/warm tailer ordering.** Warm: tailer attaches `from: :end` BEFORE the prompt
   is sent; cold: prompt first (claude creates the jsonl), then `from: :start`.
   Reordering either loses this turn's records or replays history.
6. **`started_at` captured before spawn** gates `resolve_transcript_path(since:)` so a
   reused workspace never tails a prior run's jsonl (theme 2, *stale state on disk*).
7. **`thread_id` rule in `finish_hook_turn`:** the raw hook-reported session id (nil if
   the hook never carried one), never the synthetic `repl-…` display fallback — a wrong
   handle points `--resume` at no transcript (stale-handle family, #610/#701, #613).
8. **`HookEvents.subscribe`/`unsubscribe` stay in `try`/`after`;** an interrupted
   turn's late Stop hook is expected to be drained harmlessly by the next turn's loop.
9. **Reap scoping:** owner-pid window-name encoding, the dead-owner vs own-pid
   predicates, and `stop_session`'s unregister→kill-pane→graceful_kill_tree→verify
   order must not drift (rows 3/12: scoping oscillated between killing siblings and
   missing orphans). RC-unavailable degrade must still tear down pane + process tree
   and return `{:error, :remote_control_unavailable}`.
10. **`sanitize_pane_input`** control-byte collapse is a security invariant (hostile
    payload typed into a PTY); the single trailing Enter is the only submit.
11. **`/rc` harvest always sends Esc,** even on scrape failure, so the dialog can't eat
    the first prompt's keystrokes.

**Existing test pinning:**

- `src/test/aiur/claude/repl_agent_test.exs` (1,314 lines, `async: false`, mock tmux
  control-mode transport) pins nearly every flow **through the facade's public API**:
  spawn/ready/resume/RC-attach (banner + `/rc` harvest + degrade), not-ready and
  spawn-error teardown, stop_session, both sweeps' scoping, transcript turns
  (complete/cold-start/retype/`:prompt_not_delivered`/`:turn_timeout`/`:repl_gone`/
  session reuse), mid-turn operator inject + non-deliver-now ignore, all three pause
  outcomes, hook turns (submit-wait, best-effort Enter, Stop completion, no
  transcript-event emission, operator inject, `:repl_gone`), operator-message
  sanitization, and `interrupt`. Because it drives the facade, it survives every wave
  unchanged and is the refactor's primary safety net.
- `src/test/aiur/coding_agent_test.exs:152` pins the adapter mapping
  `"claude-repl" → Aiur.Claude.ReplAgent` (facade name must not change).

**Characterization gaps to close before/during the split:**

- **Hook-path pause:** no test sends `{:pause_agent, id}` into `await_hook_turn`
  (all pause tests exercise the transcript path). Wave 5 moves this branch blind today.
- **Hook-path backstop `:turn_timeout`** (fully silent session) and the
  deadline-reset-on-PostToolUse behavior are untested.
- **`maybe_hook_settings`:** no test covers `--settings` flag injection on an RC spawn
  with an identifier, nor the no-dashboard-url / write-failure degrade to nil.
- **Cold-start `:no_transcript` failure** (jsonl never materializes) is untested — only
  the success path is.
- **`/rc` harvest failure still sends Esc** (dialog scrape times out) is untested.
- **`stop_session` with a live os_pid** (graceful_kill_tree engaged, `pid_gone?`
  verification) is untested (tests use nil/dead pids).
- **`sweep_repl_panes` when `list_windows` errors** (returns `:ok`) is untested.
