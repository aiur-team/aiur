# Duplication Map — Infrastructure Code

Scope: pollers/retry/backoff/dedup, process kill/reap trees, tmux send-keys/capture
paths, path/identity derivation, JSON decode + error-wrap, alert/event emission,
and shell↔Elixir duplication between `scripts/aiurdev` / `aiur-engine.sh` and the
BEAM. All paths relative to `/home/orangekid/github/aiur`. Only clusters where the
same logic is genuinely maintained in more than one place are listed; each entry
names the cluster, gives line refs for the duplicated shape, and proposes the
consolidation.

Note on `scripts/aiurdev`: post launcher-unification it is a ~420-line shim; the
old aiurdev↔engine duplication is gone. The remaining shell duplication is
(a) engine↔BEAM mirrors and (b) intra-engine repetition, both covered below.

---

## 1. Periodic-tick GenServer skeleton (pollers)

**Paths**
- `src/lib/aiur/events/ls_remote_ticker.ex:59-99` (start_link / init with `interval_ms` + `start_paused?` / `handle_info(:tick)` / catch-all `handle_info` / `schedule_tick/1`)
- `src/lib/aiur/progress_checkin/worker.ex:47-87` (identical skeleton)
- `src/lib/aiur/logs/retention.ex:39-81` (identical skeleton + sync `sweep/1` call)
- `src/lib/aiur/agent_resource_guard.ex:25-102` (variant: no `start_paused?`, rescue-wrapped tick)

**Shape.** Four GenServers implement the same "self-rescheduling periodic worker"
frame by hand: `interval_ms` option with a module default, `start_paused?` for
tests, `unless state.start_paused?, do: schedule_tick(...)` in `init/1`,
`handle_info(:tick)` that runs the body then re-schedules, a catch-all
`handle_info(_other)`, and the identical `schedule_tick(interval_ms) when
is_integer(interval_ms) and interval_ms > 0, do: Process.send_after(self(), :tick, ...)`.
Each also grew its own crash-isolation idiom (ticker: rescue/catch around
`run_tick`; retention: rescue in `run_sweep`; guard: try/rescue/after in the
handler; checkin: try/rescue around the orchestrator call) and its own
test-injection seam with *inconsistent shapes* (`:publisher` as arity-3 fun in
the ticker, `{mod, fun}` or arity-2 fun in the checkin worker, `:cap_mb_fun` /
`:current_session_fun` in retention, `:entries_fun`/`:kill_fun` in the guard).

**Consolidation.** One `Aiur.PeriodicWorker` (a `use`-macro or behaviour with
`c:tick/1 :: state`): owns interval/start_paused?/scheduling/catch-all
`handle_info` and a mandatory rescue-wrapped tick so "a crashed sweep silently
stops running" can never regress per-module. `LsRemoteTicker` keeps its variable
`next_delay_ms` (the behaviour's `tick/1` return can carry the next delay);
retention keeps its sync `:sweep` call as an extra callback. Body logic
(ls-remote diffing, checkin publish, size-cap reaping, load-generator trimming)
stays module-specific. Standardize the injectable-fn seam shape (plain arity-N
funs) while touching them.

---

## 2. GitHub connectivity streak → backoff → alert plumbing

**Paths**
- `src/lib/aiur/events/ls_remote_ticker.ex:137-183` (`note_connectivity_success`, `note_connectivity_failure`, `connectivity_streak_count/1`, `normalize_backoff_ms/2` incl. the `:escalate -> max_backoff_ms` clause, `Alerts.emit_custom("system.github.connectivity_lost", ...)` at 156-161)
- `src/lib/aiur/orchestrator.ex:1432-1490` (`note_github_connectivity_failure`, `connectivity_streak_count/2`, `normalize_github_backoff_ms/2`) and `orchestrator.ex:1511-1519` (`emit_github_connectivity_alert` — byte-identical `Alerts.emit_custom("system.github.connectivity_lost", message, reason:, needs_attention: true, severity: "warning")`)

**Shape.** Both call the shared `Aiur.GitHub.Connectivity` policy module, but the
*fold* around it — classify failure, `note_failure/3`, iterate returned alerts and
emit the `system.github.connectivity_lost` operator blocker with the exact same
options, compute streak count with the same `{_classification, count} when count > 0`
pattern-match-else-1, run `backoff_ms/3`, and normalize `:escalate` /
non-integer results back to the base interval — is written twice. The escalation
policy (#617) therefore has two call-site copies that must change together (e.g.
changing alert severity or the streak-count default requires two edits).

**Consolidation.** Move the fold into `Aiur.GitHub.Connectivity` itself, e.g.
`Connectivity.record_failure(streaks, source, classification, base_interval_ms, repo: ...)
:: {streaks, backoff_ms}` that internally emits the alert(s) (or returns them
with a single shared `emit/1`). The ticker keeps its per-source `:ls_remote`
key and single-delay state; the orchestrator keeps its `github_poll_delays`
map. `connectivity_streak_count` and the `:escalate` normalization live only in
the shared module.

---

## 3. GitHub payload sanitize→publish pipeline

**Paths**
- `src/lib/aiur/events/github_comments_poller.ex:298-312` (`publish_comment/4`: `Map.put(:source, :github) |> Sanitizer.scrub() |> Sanitizer.stamp_author_trust(actor:) |> Sanitizer.put_comment_message()` then `Publisher.publish/3`)
- `src/lib/aiur/events/github_firehose.ex:178-185` (same 4-step pipeline inside `do_publish_one/2`)
- `src/lib/aiur/orchestrator.ex:1612-1616` and `orchestrator.ex:1770-1775` (PR command scan: `stamp_author_trust` at annotate time, then `scrub |> put_comment_message` before publish — same steps, split across two sites)

**Shape.** Every GitHub-sourced event must be stamped `source: :github`,
scrubbed (truncate/redact/escape), trust-stamped from the actor, and given the
comment-message convenience field *before* `Publisher.publish`. That invariant is
enforced by copy-pasted pipelines at three producers; skipping a step at a new
producer (or reordering scrub vs. stamp) silently weakens the injection-safety
layer, and today nothing structural prevents that.

**Consolidation.** A single entry point — either
`Aiur.Events.Sanitizer.github_payload(payload, actor)` returning the fully
prepared map, or better `Publisher.publish_external(topic, payload, opts)` that
applies the pipeline itself when `source: :github` is passed. Producers keep
only what differs: topic construction, dedup keys (already centralized in
`GithubKeys`), and `bypass_contamination` decisions.

---

## 4. Deadline-poll loops, incl. a duplicated first-paint detector

**Paths**
- `src/lib/aiur/opencode/attach_pool.ex:879-907` (`wait_for_paint/2` + `do_wait_for_paint` + `retry_wait_for_paint`: capture-pane until `"Build · issue-"` appears, 100ms poll, budget deadline)
- `src/lib/aiur/pane_manager.ex:1140-1215` (`detect_convo_first_paint` + `do_detect_convo_paint` + `wait_and_retry_convo_paint`: the *same* marker string `"Build · issue-"`, same capture-pane loop, plus perf event)
- `src/lib/aiur/claude/remote_control.ex:282-299` (`await_exit/do_await_exit`: deadline + `Process.sleep(@kill_poll_ms)`)
- `src/lib/aiur/claude/repl_agent.ex:262-290, 302-328, 757-771, 796-826, 842-858, 883+` (six hand-rolled deadline loops: RC evidence, session URL, paste-landed, echo/retype, transcript wait, turn wait)

**Shape.** The generic frame — compute `deadline = monotonic + budget`, check a
condition, `Process.sleep(interval)`, recurse until deadline — is re-implemented
at least nine times with per-site constants. Worst case is the opencode
convo-paint detector: `attach_pool.ex` and `pane_manager.ex` maintain two full
copies of the same marker-scrape loop (same tmux command, same magic string,
different budgets 30s/30s, poll 100ms/100ms); a change to opencode's paint
banner must be found and fixed in both.

**Consolidation.** (a) A tiny `Aiur.Poll.until(fun, budget_ms, interval_ms)`
helper (returns `{:ok, val} | :timeout`) absorbs the frame everywhere; each site
keeps only its predicate. (b) Extract one `Aiur.Opencode.PaintDetect`
(marker constant + capture loop) used by both AttachPool prewarm and
PaneManager, with the perf-event emission as an optional callback — the marker
string then lives in exactly one module. The repl_agent's two deliberate
delivery policies (RC "never clear/retype" vs. non-RC "clear+retype") stay as
separate policies but share the paste→poll-echo primitive.

---

## 5. Raw tmux command strings bypassing the typed `Aiur.Tmux` API

**Paths**
- Typed API: `src/lib/aiur/tmux.ex:288-306` (`capture_pane/2`, `kill_pane/2` — kill_pane treats "can't find pane" as `:ok` at `tmux.ex:649-663`), args-based exec `tmux.ex:807-827`.
- String-built bypasses: `src/lib/aiur/pane_manager.ex:522, 572, 588, 837` (`Tmux.command(state.tmux, "kill-pane -t #{id}")`), `pane_manager.ex:620, 1163` (`"capture-pane -p -t #{id}"`); `src/lib/aiur/opencode/slot.ex:481, 797, 1079, 1275` (capture + kill strings); `src/lib/aiur/opencode/attach_pool.ex:887` (capture string).

**Shape.** `Aiur.Tmux` exposes typed, arg-vector wrappers precisely because
`command/3` re-tokenizes the string with a homegrown quote-splitter
(`tmux.ex:960-997`) that mangles whitespace/quotes. Yet PaneManager, Slot, and
AttachPool build `"kill-pane -t #{pane_id}"` / `"capture-pane -p -t #{pane_id}"`
strings at ~10 sites. The behavioral duplication is real: the typed
`kill_pane/2` has idempotent already-gone handling that the raw-string callers
silently lack, and any future hardening (interpolation escaping, retries,
socket handling) must be duplicated into every string caller.

**Consolidation.** Route all pane kill/capture through `Tmux.kill_pane/2` and
`Tmux.capture_pane/2`; add the two or three missing wrappers the raw callers
need (`resize-window`, `select-layout even-horizontal`, `pipe-pane`) as typed
functions. Demote `Tmux.command/3` to test/mock-only (or delete it) so the
string-splitting path can't accrete new callers.

---

## 6. Process-tree collection + graceful-kill escalation (Elixir side)

**Paths**
- Canonical: `src/lib/aiur/claude/remote_control.ex:229-299` (`graceful_kill/1` TERM→wait→KILL, `graceful_kill_tree/1`, `collect_descendants/1` via `pgrep -P` recursion, `await_exit`)
- Copy A: `src/lib/aiur/agent_resource_guard.ex:67-73, 136-160` (`collect_descendants/2` + `children/1` — same pgrep -P recursion re-implemented, plus `parse_pid_list`)
- Copy B: `src/lib/aiur/agent_resource_guard.ex:162-178` (`proc_info/1` reads `/proc/<pid>/cmdline`, NUL→space) vs `src/lib/aiur/process_reaper.ex:321-326` (`read_cmdline/1`, identical transform)
- Divergent kill: `src/lib/aiur/opencode/server.ex:121-141` (`reap_opencode_children`: bare `kill -TERM`, no await, no KILL escalation — a third kill semantics)

**Shape.** "Walk a process tree with `pgrep -P`" exists twice (RemoteControl,
AgentResourceGuard) with the guard's copy adding only injectability; "read and
normalize /proc cmdline" exists twice (ProcessReaper, AgentResourceGuard); and
TERM/KILL semantics exist in two strengths (RemoteControl's escalating
`graceful_kill` vs opencode Server's fire-and-forget TERM). These are the
correctness-critical kill paths — the pid-reuse and reparenting subtleties
documented in RemoteControl/#453 apply to all of them, but fixes land in one
copy at a time.

**Consolidation.** New `Aiur.OsProcess` (or extend `Aiur.Os`): `descendants/1`,
`graceful_kill/2` (grace opts), `graceful_kill_tree/2`, `alive?/1`,
`cmdline/1`. RemoteControl keeps its RC-specific sweeps but delegates
primitives; AgentResourceGuard keeps only its load-generator classification;
ProcessReaper keeps registry/drain semantics and calls `OsProcess.cmdline/1`;
opencode Server either justifies its TERM-only kill in one comment or adopts
`graceful_kill` (it exec's, so single-pid is fine — but the escalation should be
shared).

---

## 7. Shell↔Elixir mirrored reap stack (engine ↔ BEAM)

**Paths** (engine = `packaging/npm/aiur-cli/libexec/aiur-engine.sh`)
- pid tree: engine `agent_pid_tree` :878-884 ↔ `remote_control.ex:266-280` `collect_descendants` (comment at engine:872 says "mirroring Aiur.RemoteControl.collect_descendants")
- pid-reuse comm guard: engine `agent_pid_matches` :890-896 ↔ `process_reaper.ex:308-319` `cmdline_guard` (engine comment: "Mirrors the BEAM-side cmdline guard")
- workspace cwd sweep: engine `canonical_workspace_root` :1027-1034, `workspace_root_is_shallow` :1036-1044, `workspace_cwd_pids` :1046-1060, `shell_protected_pid_list` :1062-1070, `reap_workspace_cwd_agents` :1072-1115 (max 6 sweeps, 0.1s backoff) ↔ `remote_control.ex:347-485` `reap_workspace_agents` + `sweep_root` + `shallow_root?` + `workspace_agent_pids` + `workspace_agent?` + `self_pid_tree` (`@workspace_reap_max_sweeps 6`, `@workspace_reap_backoff_ms 100`)
- TERM→wait→KILL escalation, three in-engine copies: `kill_beams_matching` :626-639 (30×0.1s), `kill_pid_with_escalation` :665-675 (20×0.1s), `reap_aiur_agents` tree kill :929-941 (20×0.1s), plus `kill_control_rpc_process` :1467-1483 (0.2s) ↔ `remote_control.ex:235-247` `graceful_kill`
- pidfile handoff contract: `process_reaper.ex:242-267` writes `pid <pid> <comm>` lines to `AIUR_AGENT_TMPFILE`; engine `reap_aiur_agents` :909-941 parses that exact format.

**Shape.** The dead-BEAM reaper in bash is a deliberate line-by-line mirror of
the live-BEAM reaper in Elixir: same tree-walk, same comm-substring pid-reuse
guard, same canonicalize-then-refuse-shallow-root safety check, same
6-sweep/100ms retry loop, same TERM→KILL grace pattern. Every safety fix made
on one side (the #453 symlink canonicalization, the shallow-root refusal, the
comm guard) had to be re-implemented on the other, and the engine additionally
repeats its own escalation loop four times with slightly different waits.

**Consolidation.** The cross-language mirror cannot be removed (a dead BEAM can
kill nothing), so: (a) inside the engine, collapse the four escalation loops
into one `kill_tree_with_escalation <pids...>` function and have
`kill_beams_matching` / `reap_aiur_agents` / `kill_control_rpc_process` call it;
(b) pin the mirror with a cross-language conformance test (fixture process tree
+ /proc fixture: assert the bash sweep and `RemoteControl.reap_workspace_agents`
select the same kill set and both refuse the same shallow roots — the shell side
is already testable via `src/test/aiur_engine_test.exs`); (c) document the
`AIUR_AGENT_TMPFILE` line format in exactly one place (a comment block both
files reference) since it is a serialization contract between the two mirrors.

---

## 8. Control-RPC marker protocol duplicated across languages

**Paths**
- `src/lib/aiur/agent_control_cli.ex:8` — `@exit_marker "__AIUR_CONTROL_EXIT__:"`, printed by every control command.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh:1539` — `local marker="__AIUR_CONTROL_EXIT__:"`, parsed by `run_control_rpc` :1528-1605 into the process exit code; also filters `:ok`/blank lines :1587-1595.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh:1190-1204` — `probe_control_liveness` inlines an Elixir expression printing `__AIUR_CONTROL_READY__` / `__AIUR_CONTROL_NOT_READY__`; those markers exist only in the shell string (the Elixir side is generated ad hoc via rpc).

**Shape.** The stdout marker is the *only* success/failure channel between the
BEAM control CLI and the shell (FI-CLI-029) and its literal is maintained in two
languages; the shell additionally hard-codes which output lines are noise
(`:ok`, empty). The readiness probe embeds a second marker pair plus a
non-trivial Elixir expression inside a bash string — logic about
`Aiur.Orchestrator.status/2` timeouts living in the shell.

**Consolidation.** Can't share a constant across languages at runtime, so
minimize and pin: move the liveness expression into a real function
(`Aiur.AgentControlCLI.probe/0`) so the shell only carries
`"Aiur.AgentControlCLI.probe()"` and the marker; add a conformance test that
greps both files for the marker literal and pins them equal (precedent:
FI-ENG-064's MIN_TMUX pin test). Optionally have `run_control_rpc` pass the
marker in (`status(marker: "...")`) so only the shell defines it.

---

## 9. Project-root / config discovery duplicated (two languages + twin walk)

**Paths**
- Elixir: `src/lib/aiur/workflow.ex:35-57` (`detect_run_folder_config` / `config_path_candidates`: `./.aiur/config` → `./.aiurconfig` → `~/.aiur/config` → `~/.aiurconfig`)
- Shell: `aiur-engine.sh:61-82` (`aiur_project_root`: walk up from `$PWD`, stop at `$HOME`, look for `.aiur/config` or `.aiurconfig`) and — a second, near-identical copy in the same file — `aiur-engine.sh:84-101` (`aiur_project_root_source`: the same walk, returning `repo|cwd|env` instead of the path)
- Downstream identity: `aiur-engine.sh:108-117` (`aiur_instance_key` sha256 of canonical root) — shell-only, keys node/session/socket names.

**Shape.** Which files count as "a repo-local config" and where discovery stops
is encoded independently in `workflow.ex` and the engine (FI-ART-001 flags this
as two-language duplication that must stay in agreement, #443). Within the
engine, the walk itself is written twice — `aiur_project_root` and
`aiur_project_root_source` differ only in what they print, so adding a new
config filename (e.g. a future `.aiur/config.yml`) requires three edits, two of
them in the same file.

**Consolidation.** Engine-internal: merge the two walks into one function that
emits `root<TAB>source` and have both callers parse it. Cross-language: the
config-filename list is the shared contract — extract it into one obvious pinned
pair (a bash array + an Elixir module attribute, each commented as mirrors) and
add a test that a repo fixture resolved by `Workflow.detect_run_folder_config/0`
and by `aiur_project_root` (already driven in `src/test/aiur_engine_test.exs`)
agree for the repo-local, global, and no-config cases.

---

## 10. Identifier/path sanitization and the `~/.aiur/logs` literal

**Paths**
- `src/lib/aiur/workspace.ex:875-877` — `safe_identifier/1`: `String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")`
- `src/lib/aiur/opencode/config.ex:139-142` — `safe_identifier/1`: byte-identical implementation (public; used by `opencode/protocol.ex`, `session_writer_registry.ex`, `opencode/config.ex:119`)
- `src/lib/aiur/config/paths.ex:61-64` — `sanitize/1`: same character class, no `"issue"` default
- `src/lib/aiur/test_reset.ex:596` — same regex inlined
- Variant: `src/lib/aiur/pane_manager.ex:1786` — node-name sanitize `[^A-Za-z0-9_-]` → `"-"` (dots disallowed in the node short-name, so genuinely different)
- Log home literal: `src/lib/aiur/log_file.ex:68` (`~/.aiur/logs/<session>`), `src/lib/aiur/logs/retention.ex:165` (`default_root`), `aiur-engine.sh:440` (`$HOME/.aiur/logs/<ts>-<pid>`), `scripts/aiurdev:355` (`$HOME/.aiur/logs/*` in `--clear`)

**Shape.** The issue-identifier filesystem-safety rule exists as two identical
private/public functions plus an inline copy; because both workspace naming
(`<root>/<repo>/<safe_id>`) and opencode model IDs (`issue-<safe_id>`) must
produce the *same* string for the same ticket, a divergence between the copies
would break the workspace↔session correlation silently. Separately, the unified
log home path is derived in three places across two languages; Retention sweeps
whatever `~/.aiur/logs` is while LogFile/the engine mint session dirs under it —
if one moves, retention silently stops bounding the disk (its own doc calls this
the disk-safety mechanism).

**Consolidation.** One `Aiur.Identifier.sanitize/1` (or promote
`Config.Paths.sanitize/1` and add the `|| "issue"` default as
`safe_issue_id/1`); `Workspace` and `Opencode.Config` delegate; test_reset uses
it. PaneManager's node-name variant stays but gains a comment saying why it
differs. For the log home: `Aiur.Config.Paths.log_home/0` (`~/.aiur/logs`)
consumed by LogFile and Retention; the engine keeps its own copy (it must run
pre-BEAM) but references the Elixir constant in a mirror comment, and
`aiurdev --clear` already defers to `AIUR_AGENT_IR_LOGS_PARENT` when sandboxed.

---

## 11. Atomic write-then-rename

**Paths**
- `src/lib/aiur/json_store.ex:31-50` — tmp with unique suffix + fsync + rename (strongest guarantee)
- `src/lib/aiur/shutdown.ex:87-98` — `atomic_write/2`: fixed `.tmp` sibling + rename, rm on failure (workspace-root handoff file)
- `src/lib/aiur/claude/remote_control.ex:103-114` — `write_atomic/2`: unique-suffix tmp + rename, rm on failure (`~/.claude.json` trust edit)
- `src/lib/aiur/agent_skills.ex:103-117` — `stage_and_rename/2`: tmp dir + rename (directory-shaped variant)
- Shell analogue: `aiur-engine.sh:960-978` `write_aiur_instance_record` (mktemp + mv)

**Shape.** Three Elixir modules each hand-roll "write sibling temp, rename into
place, clean up on failure" with different tmp-naming and durability choices:
JsonStore fsyncs, the other two don't; Shutdown uses a fixed `.tmp` name
(concurrent writers would clobber each other's staging file — exactly the bug
JsonStore's unique suffix comments warn about). The guarantees each caller
actually needs are the same ("reader sees old or new, never a prefix").

**Consolidation.** One `Aiur.Fs.atomic_write(path, contents, fsync: bool)`
(JsonStore's implementation, fsync optional) used by Shutdown and RemoteControl;
JsonStore becomes a thin JSON codec over it. The directory variant in
AgentSkills can stay (different shape) or become `Aiur.Fs.atomic_write_dir/2`.
The shell copy stays (pre/post-BEAM lifecycle) — it is already minimal.

---

## 12. Headless app-server backend twins (claude vs codex)

**Paths**
- `src/lib/aiur/claude/coding_agent.ex` (992 lines) and `src/lib/aiur/codex/coding_agent.ex` (1997 lines) — ~47 same-named functions: `start_session/do_start_session`, `start_port`, `stop_port` (:839-857 vs :1523-1552, codex adds tree-reap), `port_metadata`, line-buffered stream loop `receive_loop`/`handle_incoming` (claude :337-390, codex :534+), `handle_decoded_incoming` JSON-RPC dispatch, `handle_malformed_incoming`/`log_non_json_stream_line`, pause protocol (`handle_pause_request`, `interrupt_turn`, `continue_after_turn_interrupted` — FI-CLD-009 / FI-CDX-033 describe the same protocol), operator-queue handling (`handle_operator_queue_update`, `handle_claimed_operator_response`, `fail_pending_operator_requests`), `normalize_event`/`normalize_usage`/`normalize_rate_limits`/`token_value`, `with_timeout_response`, `issue_context`/`issue_identifier`, `validate_workspace_cwd` (FI-CDX-019: codex copy is identical to the claude copy and only the claude copy is tested).

**Shape.** Both backends drive a JSON-RPC-over-stdio app-server through an
Erlang Port with the same framing (accumulate `pending_line`, split on newline,
`Jason.decode`, dispatch on `id`/`method`), the same pause/interrupt state
machine, the same operator-message queue semantics, and the same
workspace-cwd/symlink-escape validation. This is the largest single duplication
in the codebase (~1000 lines of parallel logic); protocol-level fixes (pause
race handling, malformed-line logging, stop_port reparenting) have already
drifted (claude's `stop_port` lacks codex's tree-reap — each side fixed a
different subset).

**Consolidation.** Extract `Aiur.AppServer.PortSession` (spawn/registration
with ProcessReaper, line framing + JSON decode + request-id correlation,
timeout wrapper, stop_port with tree-reap as the single semantics) and
`Aiur.AppServer.TurnLoop` (turn lifecycle, pause protocol, operator queue,
completion status mapping) parameterized by a small vendor callback module
(initialize payload, method names, transcript extractor, usage normalizer —
codex's multi-source usage/rate-limit extraction genuinely differs and stays
vendor-side). `validate_workspace_cwd` moves next to `PathSafety` and both
backends call it; the existing claude tests then cover the shared copy.

---

## 13. Owner-pid-tagged orphan sweeps at boot

**Paths**
- `src/lib/aiur/claude/remote_control.ex:313-328, 487-521` — `reap_orphaned_servers/0`: scan `$TMPDIR/aiur-rc` for `rc-<owner_pid>-<n>.debug`, regex the owner pid out, `os_process_alive?` (kill -0), pkill + rm when dead
- `src/lib/aiur/claude/repl_agent.ex:366-370, 385-436` — `reap_orphaned_panes/0`: scan tmux windows for `aiur-repl-<owner_pid>-<n>`, `parse_owner_pid`, `os_pid_alive?`, kill pane + `graceful_kill_tree` when dead

**Shape.** Same crash-recovery idea implemented twice: resources are named with
the owning BEAM's OS pid at creation; at boot, enumerate them, parse the owner
pid from the name, keep those whose owner is alive (side-by-side instance
safety), reap the rest. Each has its own pid-liveness check (`kill -0` shell-out
vs. the same wrapped differently) and its own owner-pid regex.

**Consolidation.** Small shared helper: `Aiur.OsProcess.alive?/1` (from cluster
6) plus an `owner_pid_from_name(name, prefix)` utility, so the naming convention
(`<prefix><owner>-<n>`) is defined once and both sweeps become enumerate +
filter + kill. Low urgency, but worth folding while building `Aiur.OsProcess`.

---

## 14. JSONL/line decode-or-skip wrappers

**Paths**
- `src/lib/aiur/claude/remote_control.ex:220-225` (`decode_transcript_record`: decode → `[record]` / `[]`)
- `src/lib/aiur/claude/transcript_tailer.ex:203-208` (`decode`: `{:ok, record}` / `:error`)
- `src/lib/aiur/alert_feed.ex:104-111` (trim → decode → map-or-nil)
- `src/lib/aiur/codex/transcript.ex:210-217` (decode-or-wrap-`%{"raw" => str}`)
- `src/lib/aiur/agent_log.ex:61-67` (`with "{" <> _ ... Jason.decode` → nil)
- `src/lib/aiur/json_store.ex:57-72` (file read → decode → default-on-enoent)

**Shape.** Six private one-off wrappers around `Jason.decode/1` for
line-oriented logs/transcripts, each choosing a slightly different "malformed
line" convention (drop, `:error`, nil, raw-wrap). The drop-vs-wrap decisions are
mostly incidental, and every new tailer re-invents one.

**Consolidation.** `Aiur.Jsonl` with `decode_line/1 :: {:ok, map} | :skip` and
`stream(path)`; callers that need a distinct malformed policy (codex's raw-wrap
is load-bearing for display) keep a one-line adapter. This is the lowest-value
cluster here — worth doing opportunistically when files are already being
touched, not as a standalone pass.

---

## 15. Dual tmux conf copies with live drift

**Paths**
- `scripts/aiur.tmux.conf` (dev copy) vs `packaging/npm/aiur-cli/share/aiur.tmux.conf` (shipped copy)
- Diff today: scripts copy adds `terminal-features "*:sync"` (DEC 2026 flicker fix), the `C-q` hide binding, and the *corrected* inline `#{@aiur_ctrlc}` run-shell form; the shipped copy still uses the buggy `h=...; $h` re-parse form (silently falls through to raw kill-pane) and lacks C-q/sync. FI-ENG-046 flags this drift explicitly.

**Shape.** Two full copies of the session's tmux configuration are maintained by
hand and have already diverged in behavior-relevant ways — the Ctrl+C helper
quoting bug is *fixed only in the dev copy*, so installed users and dogfood runs
exercise different pane-close semantics. `resolve_tmux_conf`
(`aiur-engine.sh:609-620`) picks whichever copy the run was launched with, so
the drift is invisible in dev testing.

**Consolidation.** Make `packaging/npm/aiur-cli/share/aiur.tmux.conf` the single
canonical file: port the sync/C-q/quoting fixes into it, then either delete
`scripts/aiur.tmux.conf` and point dev launches at the share copy (aiurdev
already runs the same engine, which already resolves the share copy relative to
`engine_dir`) or reduce scripts/ to a symlink. Add
`scripts/verify-ctrlc-binding.sh` to CI against the canonical copy.

---

## Priority ordering (by blast radius × drift already observed)

1. **#12 app-server backend twins** — largest mass, drift already present, untested codex copies.
2. **#7 shell↔Elixir reap stack** — correctness-critical kill paths, four in-engine escalation copies.
3. **#15 tmux conf drift** — shipped users currently run the buggy Ctrl+C form.
4. **#3 sanitize→publish pipeline** — security-relevant invariant enforced by convention only.
5. **#2 connectivity fold** and **#1 periodic-worker skeleton** — mechanical, low-risk extractions.
6. **#5 typed-Tmux adoption**, **#6 OsProcess**, **#10 sanitize/log-home**, **#11 atomic write**, **#4 Poll.until + PaintDetect**.
7. **#8/#9 cross-language pins** — mostly conformance tests, small code moves.
8. **#13/#14** — opportunistic.
