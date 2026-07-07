# T-016: Migrate agent_runner residual backend branches

**Phase:** 2
**Depends-on:** T-015
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_runner.ex` still hard-codes backend identity in the ~638–1059 band: `report_repl_session/3` has separate `%{backend: "claude-repl"}` and `%{backend: "claude"}` clauses, `remote_session_backend/2` inlines the claude → claude-repl remote-control promotion, `should_display_tail?/3` compares against the `"claude-repl"` literal, and `start_agent_session/3` inlines the claude-repl → claude spawn-failure fallback. Every one of these is a place a new backend would force an `agent_runner.ex` edit, defeating the seam contract in `docs/refactor/target-architecture.md` ("adding a backend = one module + one registry entry, zero edits elsewhere"), which explicitly names the promotion and the spawn-failure fallback as things that "become backend-declared capabilities, not inline `case` clauses".

T-015 formalized the `Aiur.CodingAgent.Backend` behaviour over the existing registry (`Aiur.CodingAgent.backends/0` in `src/lib/aiur/coding_agent.ex` stays the single source of backend identity). This ticket finishes the migration: it declares four backend capabilities in that registry, adds registry accessors following the existing `remote_control?/1`-style pattern, and rewrites the four `agent_runner.ex` branch sites to read them. Behavior is identical; only the dispatch mechanism changes. Rule preserved throughout: the backend is resolved once at session start (`CodingAgent.backend_for/1` → `remote_session_backend` → `start_agent_session` tags the session), and everything downstream reads `session[:backend]` (via the existing private `session_backend/1`, agent_runner.ex:2002-2003) — never re-resolved mid-session.

## Scope (exact)

All line numbers refer to `src/lib/aiur/agent_runner.ex` and `src/lib/aiur/coding_agent.ex` at the T-015 merge base. Locate code by function name if lines have drifted.

1. **Precondition check (mechanical, no judgment).** From the repo root run:
   ```
   grep -n "remote_transport\|spawn_fallback\|rc_display_tail\|runtime_report\|remote_session_backend" src/lib/aiur/coding_agent.ex
   ```
   - If a name from steps 2–3 already exists in `src/lib/aiur/coding_agent.ex` with exactly the key/function name and semantics specified below (T-015 may have pre-landed it), skip the corresponding add in steps 2–3 and use the existing one.
   - If T-015 landed an equivalent capability under a **different** name (e.g. a promotion capability not called `remote_transport`), STOP: comment the conflict on the issue (quote both names) and end your turn. Do not pick a name yourself.

2. **Declare the capabilities in the registry.** In `src/lib/aiur/coding_agent.ex`, inside `backends/0` (currently lines 69–123):
   - In the `"claude"` entry, add these two keys (alongside the existing `resumable:`/`models:` keys):
     ```elixir
     # Remote control physically rides the persistent-REPL transport, so a
     # remote-on claude dispatch is promoted to this backend (carrying the
     # resolved model).
     remote_transport: "claude-repl",
     # The headless `bash -lc` wrapper does not exec; report its os pid so
     # brutal-kill teardown can tree-reap the reparented claude/node children.
     runtime_report: :headless_wrapper,
     ```
   - In the `"claude-repl"` entry, add these three keys:
     ```elixir
     # A tmux/RC start failure must never strand an issue: degrade once to
     # the headless claude backend (with :remote_control stripped).
     spawn_fallback: "claude",
     # Only the hook-driven RC REPL needs the pane display tailer; every
     # other backend streams its own rich transcript.
     rc_display_tail: true,
     # The persistent pane + REPL os pid are what an abort path must reap.
     runtime_report: :repl_pane,
     ```
   Do not change any existing key or value in the registry.

3. **Add four registry accessors** to `src/lib/aiur/coding_agent.ex`, placed directly after the existing `remote_control?/1` function (currently lines 375–381), following its exact `Map.fetch`/default pattern:
   ```elixir
   @doc """
   The transport backend a remote-control-ON dispatch actually runs on.
   A backend with a registry-declared `remote_transport` is promoted to
   that transport (carrying the resolved model); backends without the
   capability — and every RC-off dispatch — run as resolved.
   """
   @spec remote_session_backend(backend(), boolean()) :: backend()
   def remote_session_backend(backend, true) do
     case Map.fetch(backends(), backend) do
       {:ok, entry} -> Map.get(entry, :remote_transport, backend)
       :error -> backend
     end
   end

   def remote_session_backend(backend, _rc?), do: backend

   @doc """
   The backend to retry `start_session` on when this backend's spawn
   fails, or nil when a start failure is final. Declared only by the
   persistent REPL, which degrades once to headless claude.
   """
   @spec spawn_fallback_backend(backend()) :: backend() | nil
   def spawn_fallback_backend(backend) do
     case Map.fetch(backends(), backend) do
       {:ok, entry} -> Map.get(entry, :spawn_fallback)
       :error -> nil
     end
   end

   @doc """
   Whether a remote-control session on this backend feeds the pane
   display tailer. True only for the hook-driven RC REPL, whose hook
   path alone paints a sparse skeleton; every other backend streams its
   own rich transcript and must not get a second display source.
   """
   @spec rc_display_tail?(backend()) :: boolean()
   def rc_display_tail?(backend) do
     case Map.fetch(backends(), backend) do
       {:ok, entry} -> Map.get(entry, :rc_display_tail, false)
       :error -> false
     end
   end

   @doc """
   How a live session's OS-level runtime is reported to the orchestrator
   for brutal-kill teardown: `:repl_pane` (pane_id / os_pid /
   session_url), `:headless_wrapper` (the non-exec bash wrapper pid to
   tree-reap), or nil (the backend's ProcessReaper registration already
   covers it).
   """
   @spec runtime_report(backend()) :: :repl_pane | :headless_wrapper | nil
   def runtime_report(backend) do
     case Map.fetch(backends(), backend) do
       {:ok, entry} -> Map.get(entry, :runtime_report)
       :error -> nil
     end
   end
   ```

4. **Rewrite `report_repl_session/3`** in `src/lib/aiur/agent_runner.ex` (currently lines 634–667: the comment block, the `"claude-repl"` clause, the `"claude"` clause, and the catch-all). Replace all of it with exactly:
   ```elixir
   # The live session's OS-level runtime (REPL pane + agent os pid, or the
   # headless wrapper's bash pid) is owned by this runner task. An
   # abort/shutdown brutally kills the task, skipping the `after
   # stop_session` cleanup, so report it to the orchestrator's running
   # entry — the only place an abort path can still reach it. What gets
   # reported is the backend's registry-declared `runtime_report`
   # capability (`Aiur.CodingAgent.runtime_report/1`).
   defp report_repl_session(recipient, %Issue{id: issue_id}, session)
        when is_binary(issue_id) and is_pid(recipient) do
     case session_runtime_info(session) do
       nil ->
         :ok

       info ->
         send(recipient, {:repl_session_runtime, issue_id, info})
         :ok
     end
   end

   defp report_repl_session(_recipient, _issue, _session), do: :ok

   defp session_runtime_info(session) do
     case CodingAgent.runtime_report(session_backend(session)) do
       :repl_pane ->
         %{
           pane_id: Map.get(session, :pane_id),
           os_pid: Map.get(session, :os_pid),
           session_url: Map.get(session, :session_url)
         }

       :headless_wrapper ->
         case headless_os_pid(session) do
           nil -> nil
           pid -> %{headless_os_pid: pid}
         end

       nil ->
         nil
     end
   end
   ```
   Keep `headless_os_pid/1` (lines 669–676) exactly as-is. Note the message payload shapes and the `{:repl_session_runtime, issue_id, info}` tuple are wire contract with the orchestrator (FI-ORC-062) — do not alter them.

5. **Rewrite the display-tail gate.** Replace `should_display_tail?/3` and its preceding comment (currently lines 793–800) with exactly:
   ```elixir
   # Only a backend that declares the `rc_display_tail` capability (the
   # hook-driven RC REPL) feeds the display tailer. A spawn-fallback
   # headless session, codex, or an RC-off REPL streams its own rich
   # transcript and must not get a second display source.
   @doc false
   @spec should_display_tail?(String.t() | nil, boolean(), String.t() | nil) :: boolean()
   def should_display_tail?(backend, rc?, identifier) do
     rc? and CodingAgent.rc_display_tail?(backend) and is_binary(identifier)
   end
   ```
   (`rc_display_tail?/1` returns false for nil/unknown backends, preserving the old `backend == "claude-repl"` falsy result for them. Keep the function name, arity, and `@doc false` — `src/test/aiur/agent_runner_test.exs:228-243` pins it and must keep passing without edits to those tests.)

6. **Delete the local promotion function and call through the registry.** In `src/lib/aiur/agent_runner.ex`:
   - Delete `remote_session_backend/2` together with its comment block, `@doc false`, and `@spec` (currently lines 819–825).
   - In `run_codex_turns/5`, change line 691 from
     `session_backend = remote_session_backend(backend, rc?)` to
     `session_backend = CodingAgent.remote_session_backend(backend, rc?)`.

7. **Rewrite the spawn-failure fallback.** Replace `start_agent_session/3` and its comment/`@doc false`/`@spec` block (currently lines 1028–1059) with exactly:
   ```elixir
   @doc false
   # Start the resolved backend's session, tagging it with its backend so
   # later dispatch resolves the right adapter. A backend may declare a
   # registry `spawn_fallback` (the persistent REPL can fail to start: no
   # tmux, REPL never ready, RC activation failed — and a tmux/RC problem
   # must never strand an issue); on a start failure the fallback backend
   # is tried once, with `:remote_control` stripped, and the reason
   # recorded. `start_fun` is injectable for tests; production uses
   # `CodingAgent.start_session/2`.
   @spec start_agent_session(Path.t(), keyword(), (Path.t(), keyword() -> {:ok, map()} | {:error, term()})) ::
           {:ok, map()} | {:error, term()}
   def start_agent_session(workspace, opts, start_fun \\ &CodingAgent.start_session/2) do
     backend = Keyword.fetch!(opts, :backend)

     case start_fun.(workspace, opts) do
       {:ok, session} ->
         {:ok, Map.put(session, :backend, backend)}

       {:error, reason} = error ->
         case CodingAgent.spawn_fallback_backend(backend) do
           nil -> error
           fallback -> start_fallback_session(workspace, opts, start_fun, backend, fallback, reason)
         end
     end
   end

   defp start_fallback_session(workspace, opts, start_fun, backend, fallback, reason) do
     Aiur.Perf.event(:repl_start_fallback, backend: backend, reason: inspect(reason))

     Logger.warning("#{backend} start_session failed (#{inspect(reason)}); falling back to #{fallback}")

     fallback_opts = opts |> Keyword.put(:backend, fallback) |> Keyword.delete(:remote_control)

     case start_fun.(workspace, fallback_opts) do
       {:ok, session} -> {:ok, Map.put(session, :backend, fallback)}
       {:error, _} = error -> error
     end
   end
   ```
   The perf event name `:repl_start_fallback` and its `backend:`/`reason:` fields are unchanged (FI-CLD-032-adjacent perf contract). The fallback runs at most one level deep because `"claude"` declares no `spawn_fallback`. `src/test/aiur/agent_runner_test.exs:88-141` pins this function's full contract (tagging, RC-strip on retry, no fallback for non-repl backends, retry-error surfacing) and must keep passing without edits.

8. **Move the promotion tests to the module that now owns the function.** In `src/test/aiur/agent_runner_test.exs`, delete the whole `describe "remote_session_backend/2"` block (currently lines 428–438). In `src/test/aiur/coding_agent_test.exs`, inside the existing `describe "registry dispatch"` section's file (append after the last existing describe block), add exactly:
   ```elixir
   describe "remote_session_backend/2 (RC transport promotion)" do
     test "a remote-on claude issue dispatches the claude-repl transport" do
       assert CodingAgent.remote_session_backend("claude", true) == "claude-repl"
     end

     test "non-remote claude and other backends run as resolved" do
       assert CodingAgent.remote_session_backend("claude", false) == "claude"
       assert CodingAgent.remote_session_backend("codex", true) == "codex"
       assert CodingAgent.remote_session_backend("claude-repl", true) == "claude-repl"
     end

     test "an unknown backend is returned unchanged" do
       assert CodingAgent.remote_session_backend("mystery", true) == "mystery"
     end
   end

   describe "spawn_fallback_backend/1" do
     test "claude-repl declares the headless claude fallback" do
       assert CodingAgent.spawn_fallback_backend("claude-repl") == "claude"
     end

     test "backends without the capability have no fallback" do
       assert CodingAgent.spawn_fallback_backend("claude") == nil
       assert CodingAgent.spawn_fallback_backend("codex") == nil
       assert CodingAgent.spawn_fallback_backend("mystery") == nil
     end
   end

   describe "rc_display_tail?/1" do
     test "only claude-repl feeds the RC display tailer" do
       assert CodingAgent.rc_display_tail?("claude-repl")
       refute CodingAgent.rc_display_tail?("claude")
       refute CodingAgent.rc_display_tail?("codex")
       refute CodingAgent.rc_display_tail?("mystery")
     end
   end

   describe "runtime_report/1" do
     test "claude-repl reports its pane runtime" do
       assert CodingAgent.runtime_report("claude-repl") == :repl_pane
     end

     test "headless claude reports its wrapper pid" do
       assert CodingAgent.runtime_report("claude") == :headless_wrapper
     end

     test "codex and unknown backends report nothing" do
       assert CodingAgent.runtime_report("codex") == nil
       assert CodingAgent.runtime_report("mystery") == nil
     end
   end
   ```
   (`CodingAgent` is already aliased at the top of that test file.)

9. **Sweep the file for leftover literals.** Run `grep -nE '"claude(-repl)?"' src/lib/aiur/agent_runner.ex`. It must return nothing — the steps above already remove every code occurrence (lines 638, 657, 799, 824, 1044, 1049, 1052) and reword the two comments that quoted a literal (lines 794 and 821). If anything remains, it is a step you missed; fix it, do not add an exception.

10. Run the full Agent gate (below) from `src/`.

## Files

- Create: none
- Modify: `src/lib/aiur/coding_agent.ex`, `src/lib/aiur/agent_runner.ex`
- Test: `src/test/aiur/coding_agent_test.exs` (add the four describe blocks from step 8), `src/test/aiur/agent_runner_test.exs` (delete only the `remote_session_backend/2` describe block; every other test in that file must pass unmodified)

## Out of scope

- The backend adapters: `src/lib/aiur/claude/repl_agent.ex`, `src/lib/aiur/claude/coding_agent.ex`, `src/lib/aiur/codex/coding_agent.ex` — no callback additions, no signature changes.
- The T-015 behaviour module and the T-014 `Aiur.AppServer` shared core — do not edit them.
- `src/lib/aiur/orchestrator.ex` — the `{:repl_session_runtime, ...}` consumer side is untouched; the message shapes are wire contract.
- No decomposition of `agent_runner.ex` into submodules — that is T-034..T-036 (phase 3). This ticket only rewrites the four branch sites in place.
- No new backend, no registry entry removals, no changes to existing registry keys (`adapter`, `transcript`, `can_interrupt`, `safe_checkpoints`, `immediate_delivery`, `remote_control`, `resumable`, `models`, `efforts`).
- The resume gating (`load_resume_thread_id/3`, `resume_thread_id/3`, handle persistence, agent_runner.ex ~827–959) is already registry-driven via `CodingAgent.resumable?/1` — leave it byte-identical.
- `maybe_trust_remote_control_workspace/4`, `rc_session_name/2`, `maybe_put_rc_name/3`, `maybe_start_display_tailer/3` bodies — unchanged except where step 5 states.
- `src/mix.exs` (including the coverage `ignore_modules` list) and anything under `src/test/aiur/regression/`.

## Inventory-IDs

From `docs/refactor/feature-inventory/cdx.md` / `cld.md` (behaviors implemented by, or read from, the touched code):

- **FI-CDX-013** — resumability flags live in the `backends/0` registry this ticket extends; the AgentRunner local-worker resume gate must stay intact.
- **FI-CDX-015** — session-handle writer sits inside the migrated band (agent_runner.ex:926-935); byte-identical after this ticket.
- **FI-CDX-023** — `session.resumed` → first-turn prompt choice flows through `run_codex_turns/5`, whose only change is the step-6 call-site swap.
- **FI-CDX-059** — remote-worker resume disable at the AgentRunner layer; unchanged.
- **FI-CLD-026** — the `"claude-repl"` registry entry (this ticket adds capability keys to it; existing keys untouched).
- **FI-CLD-028** — RC degrade to the non-RC backend: the spawn-failure fallback this ticket makes registry-declared (`spawn_fallback`).
- **FI-CLD-029** — REPL `--resume` injection via `resume_thread_id` opts; unchanged.
- **FI-CLD-050** — workspace trust pre-seed; `maybe_trust_remote_control_workspace/4` call unchanged.
- **FI-CLD-065** — DisplayTailer started ONLY for hook-driven RC claude-repl sessions: the gate this ticket rewrites onto `rc_display_tail` (truth table must be identical).

Directly-on-point entries from `docs/refactor/feature-inventory/orc.md` (same code, catalogued under the orchestrator section):

- **FI-ORC-062** — runner runtime-info reporting (`{:repl_session_runtime, id, %{pane_id, os_pid, session_url}}` for claude-repl; `%{headless_os_pid}` for headless claude): the exact payloads step 4 must reproduce.
- **FI-ORC-066** — backend/model/effort resolution and the claude→claude-repl RC promotion this ticket moves into the registry.

## Characterization-tests

These live under the guarded path and must pass **UNMODIFIED**:

- `src/test/aiur/regression/event_flow_e2e_test.exs` (digest render through the runner-visible closure)
- Every `src/test/aiur/regression/agent_runner_*_test.exs` file created by T-013 (agent_runner drain/resume & digest characterization)
- All other files under `src/test/aiur/regression/` (blanket rule; see Executor rules)

Additionally, these existing (editable, but do-not-edit-for-this-ticket) suites pin the migrated behavior and must pass without changes: `src/test/aiur/orchestrator_deactivate_test.exs` (repl-runtime reporting on abort), `src/test/aiur/core_test.exs` (`AgentRunner.run/3` end-to-end), `src/test/aiur/claude/repl_agent_test.exs` (repl→headless fallback integration), and all of `src/test/aiur/agent_runner_test.exs` except the one deleted describe block.

## Acceptance criteria

- `grep -nE '"claude(-repl)?"' src/lib/aiur/agent_runner.ex` returns **zero lines** (no dispatch branches, no allowed residuals — the two comments that quoted literals are reworded by steps 4 and 5).
- `grep -c 'CodingAgent.remote_session_backend(' src/lib/aiur/agent_runner.ex` returns `1`, and `grep -c 'def remote_session_backend' src/lib/aiur/agent_runner.ex` returns `0`.
- `grep -c 'def remote_session_backend' src/lib/aiur/coding_agent.ex` returns `2`; `grep -c 'def spawn_fallback_backend' src/lib/aiur/coding_agent.ex` returns `1`; `grep -c 'def rc_display_tail?' src/lib/aiur/coding_agent.ex` returns `1`; `grep -c 'def runtime_report' src/lib/aiur/coding_agent.ex` returns `1`.
- `grep -c 'remote_transport:\|spawn_fallback:\|rc_display_tail:\|runtime_report:' src/lib/aiur/coding_agent.ex` returns `5` (2 keys on `"claude"`, 3 on `"claude-repl"`).
- `grep -c 'repl_start_fallback' src/lib/aiur/agent_runner.ex` returns `1` (perf event preserved).
- `grep -c 'CodingAgent.backend_for' src/lib/aiur/agent_runner.ex` returns `1` (backend resolved once, in `run_codex_turns/5`; everything downstream reads `session[:backend]`).
- `wc -l src/lib/aiur/agent_runner.ex` ≤ 2215 (the file only shrinks) and `wc -l src/lib/aiur/coding_agent.ex` ≤ 560.
- `git diff --name-only v2...HEAD` lists exactly: `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/coding_agent.ex`, `src/test/aiur/agent_runner_test.exs`, `src/test/aiur/coding_agent_test.exs`. No files created (no module-name-map impact; nothing to add to or remove from `mix.exs` `ignore_modules`, which must be untouched: `git diff v2...HEAD -- src/mix.exs` is empty).
- Every function added or rewritten by this ticket is ≤ 20 logic lines and ≤ 2 nesting levels (`session_runtime_info/1`, `start_agent_session/3`, `start_fallback_session/6`, and the four accessors all comply as written above).
- `grep -c 'describe "remote_session_backend/2' src/test/aiur/agent_runner_test.exs` returns `0`; `grep -c 'describe "remote_session_backend/2\|describe "spawn_fallback_backend/1\|describe "rc_display_tail?/1\|describe "runtime_report/1' src/test/aiur/coding_agent_test.exs` returns `4` (the new accessors are tested even though `Aiur.CodingAgent` sits in the coverage ignore list today — that list must not change in this ticket).
- `git diff v2...HEAD -- src/test/aiur/regression/` is empty.

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

- Run `mix test test/aiur/agent_runner_test.exs test/aiur/coding_agent_test.exs test/aiur/orchestrator_deactivate_test.exs test/aiur/claude/repl_agent_test.exs test/aiur/core_test.exs` from `src/` — green, with the agent_runner_test diff limited to the one deleted describe block.
- FI-ORC-062 spot-check: in a `--test` run, dispatch a `model:claude-repl` issue and abort it mid-turn from the TUI; confirm the orchestrator received the repl runtime (pane/os_pid reaped, no orphan `aiur-repl-*` tmux window or claude process survives the abort).
- FI-ORC-066 / FI-CLD-028 spot-check: dispatch a `model:remote` + `model:claude` issue and confirm it runs on the claude-repl transport with the `Aiur: <Repo> #<id> - <title>` chat title; then break the REPL path (e.g. RC unavailable) and confirm the run degrades to headless claude, completes, and logs the `repl_start_fallback` perf event.
- FI-CLD-065 spot-check: open the RC claude-repl agent's pane and confirm the full conversation backfills (display tailer alive); confirm a headless-fallback agent's pane does NOT get a second display source.
- Diff review: the `backends/0` diff adds only the five capability keys; no existing registry value changed; the `{:repl_session_runtime, ...}` payload shapes in step 4 are byte-equal to the old clauses.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
