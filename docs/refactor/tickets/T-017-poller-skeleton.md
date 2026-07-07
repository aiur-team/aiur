# T-017: Shared poller skeleton

**Phase:** 2
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:3`

## Problem / context

Per `docs/refactor/research-arch/dup-infra.md`, three infrastructure shapes are
re-implemented per poller: (cluster 1) the self-rescheduling periodic-tick
GenServer frame, hand-rolled in `src/lib/aiur/events/ls_remote_ticker.ex:59-99`
(and three other GenServers NOT in this ticket's scope); (cluster 2) the GitHub
connectivity streak → backoff → alert fold, written once in
`ls_remote_ticker.ex:137-183` and once in `orchestrator.ex:1432-1519` — the #617
escalation policy has two call-site copies that must change together; and
(cluster 3) the sanitize-then-publish pipeline (`Map.put(:source, :github) |>
scrub |> stamp_author_trust |> put_comment_message`), copy-pasted in
`src/lib/aiur/events/github_comments_poller.ex:298-312` and
`src/lib/aiur/events/github_firehose.ex:178-185`. Skipping or reordering a step
at a new producer silently weakens the injection-safety layer (FI-GH-039).

This ticket extracts the shared skeleton under the dup-infra.md consolidation
names — `Aiur.PeriodicWorker`, `Aiur.GitHub.Connectivity.record_failure`,
`Aiur.Events.Sanitizer.github_payload` — and migrates exactly three files onto
it: `github_comments_poller.ex`, `github_firehose.ex`, `ls_remote_ticker.ex`.
This is a decomposition-wave ticket: move code verbatim (extract, do not
rewrite); public function signatures and observable behavior unchanged; tick
cadences, dedup keys, cutoffs, and backoff behavior BYTE-IDENTICAL — the T-008
characterization suite pins them and must pass unmodified. This subsystem is
hotspot #1 in `docs/refactor/research-history-hotspots.md` (~35 incidents;
"every polling optimization shipped a regression"), so any deviation from the
code given below is a bug.

## Scope (exact)

Where dup-infra.md offers two spellings, this ticket fixes the choice — do not
revisit it: cluster 1 uses the `use`-macro form of `Aiur.PeriodicWorker`;
cluster 2 uses `record_failure` that internally emits (with an `:emit_fun` test
seam, per dup-infra's "standardize the injectable-fn seam shape (plain arity-N
funs)"); cluster 3 uses `Sanitizer.github_payload/2` — NOT
`Publisher.publish_external` — so the Publisher fire-and-forget hot path
(FI-EVT-002, risk high) stays untouched.

1. Create `src/lib/aiur/periodic_worker.ex` with EXACTLY this content:

   ```elixir
   defmodule Aiur.PeriodicWorker do
     @moduledoc """
     Shared skeleton for self-rescheduling periodic GenServers (pollers and
     tickers) — the periodic-tick frame from dup-infra.md cluster 1.

     `use Aiur.PeriodicWorker` injects:

       * `start_link/1` honoring a `:name` option (default: the using
         module); overridable,
       * `handle_info(:tick, state)` that runs the module's `c:tick/1`
         inside mandatory crash isolation (a crashed tick can never
         silently stop the schedule), then re-schedules using the returned
         state's `:next_delay_ms` when present, else `:interval_ms`,
       * a catch-all `handle_info(_other, state)`.

     The using module keeps its own `init/1` (module-specific state). Its
     state map MUST contain `:interval_ms` (positive integer) and
     `:start_paused?` (boolean; when `true` the first tick is not
     scheduled — tests drive `:tick` manually), and `init/1` must end with
     `{:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}`.
     """

     require Logger

     @doc """
     Runs one poll/sweep cycle. Receives the current state and returns the
     updated state. A returned `:next_delay_ms` key sets the delay before
     the next tick; otherwise `:interval_ms` is used. Raises and throws are
     caught by `run_tick/2` — the previous state is kept and the schedule
     survives.
     """
     @callback tick(state :: map()) :: map()

     defmacro __using__(_opts) do
       quote location: :keep do
         use GenServer

         @behaviour Aiur.PeriodicWorker

         @spec start_link(keyword()) :: GenServer.on_start()
         def start_link(opts \\ []) do
           name = Keyword.get(opts, :name, __MODULE__)
           GenServer.start_link(__MODULE__, opts, name: name)
         end

         @impl GenServer
         def handle_info(:tick, state) do
           state = Aiur.PeriodicWorker.run_tick(__MODULE__, state)

           Aiur.PeriodicWorker.schedule_tick(
             Map.get(state, :next_delay_ms, state.interval_ms)
           )

           {:noreply, state}
         end

         @impl GenServer
         def handle_info(_other, state), do: {:noreply, state}

         defoverridable start_link: 1
       end
     end

     @doc """
     Invokes `module.tick(state)` under the mandatory rescue/catch. On a
     raise or throw the error is logged as a warning and the previous
     state is returned unchanged, so the caller still re-schedules.
     """
     @spec run_tick(module(), map()) :: map()
     def run_tick(module, state) do
       module.tick(state)
     rescue
       error ->
         Logger.warning(
           "#{worker_label(module)} tick raised: #{Exception.message(error)} (#{inspect(error.__struct__)})"
         )

         state
     catch
       kind, reason ->
         Logger.warning("#{worker_label(module)} tick caught #{kind}: #{inspect(reason)}")
         state
     end

     @doc "Schedules the next `:tick` message to the calling process."
     @spec schedule_tick(pos_integer()) :: reference()
     def schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
       Process.send_after(self(), :tick, interval_ms)
     end

     @doc """
     Schedules the first tick unless `state.start_paused?` is true.
     Returns the state unchanged so `init/1` can end with
     `{:ok, schedule_first_tick(state)}`.
     """
     @spec schedule_first_tick(map()) :: map()
     def schedule_first_tick(state) do
       unless state.start_paused?, do: schedule_tick(state.interval_ms)
       state
     end

     defp worker_label(module), do: module |> Module.split() |> List.last()
   end
   ```

2. In `src/lib/aiur/github/connectivity.ex`, add the shared fold. Insert the
   following immediately AFTER `note_success/2` (currently lines 77-81). Do not
   change `note_failure/3`, `backoff_ms/3`, `classify_ls_remote/1`,
   `alert_message/2`, or any module attribute:

   ```elixir
   @doc """
   Shared poller-side fold over one classified failure (dup-infra.md
   cluster 2). Calls `note_failure/3`, emits the
   `system.github.connectivity_lost` operator blocker for every returned
   alert, then derives the next delay from `backoff_ms/3` using the
   source's current streak count, normalizing `:escalate` to
   `max_backoff_ms/0` and any non-integer result to `base_interval_ms`.

   Options:

     * `:repo` — `"owner/repo"` for the alert message (optional).
     * `:detail` — detail map forwarded to `backoff_ms/3` (default `%{}`).
     * `:emit_fun` — `(name, message, opts) -> term` alert emitter
       override for tests (default `Aiur.Alerts.emit_custom/3`).
   """
   @spec record_failure(streaks(), source(), classification(), non_neg_integer(), keyword()) ::
           {streaks(), non_neg_integer()}
   def record_failure(streaks, source, classification, base_interval_ms, opts \\ []) do
     {streaks, alerts} = note_failure(streaks, source, classification)
     emit_fun = Keyword.get(opts, :emit_fun, &Aiur.Alerts.emit_custom/3)

     Enum.each(alerts, fn alert ->
       message = alert_message(alert, repo: Keyword.get(opts, :repo))

       emit_fun.("system.github.connectivity_lost", message,
         reason: message,
         needs_attention: true,
         severity: "warning"
       )
     end)

     delay_ms =
       classification
       |> backoff_ms(streak_count(streaks, source), Keyword.get(opts, :detail, %{}))
       |> normalize_backoff_ms(base_interval_ms)

     {streaks, delay_ms}
   end

   @doc """
   Current consecutive-failure count for `source`, defaulting to 1 when
   the source has no recorded streak (used as the attempt count for
   `backoff_ms/3`).
   """
   @spec streak_count(streaks(), source()) :: pos_integer()
   def streak_count(streaks, source) when is_map(streaks) and is_atom(source) do
     case Map.get(streaks, source) do
       {_classification, count} when is_integer(count) and count > 0 -> count
       _ -> 1
     end
   end

   defp normalize_backoff_ms(:escalate, _base_interval_ms), do: @max_backoff_ms

   defp normalize_backoff_ms(delay_ms, _base_interval_ms)
        when is_integer(delay_ms) and delay_ms >= 0,
        do: delay_ms

   defp normalize_backoff_ms(_delay_ms, base_interval_ms), do: base_interval_ms
   ```

   In the same file's `@moduledoc`, replace the final sentence

   > `The streak state is a plain map so each poller can keep it inside its own
   > GenServer state; the functions here are pure (the alert *side effect* is the
   > caller's job — `note_failure/3` only *returns* the alerts that should fire).`

   with:

   > `The streak state is a plain map so each poller can keep it inside its own
   > GenServer state. `note_failure/3` is pure and only *returns* the alerts
   > that should fire; `record_failure/5` is the shared poller fold that emits
   > them and derives the normalized backoff delay.`

3. In `src/lib/aiur/events/sanitizer.ex`, insert immediately after
   `def scrub(other), do: other` (currently line 82):

   ```elixir
   @doc """
   Prepare a GitHub-sourced payload for `Aiur.Events.Publisher.publish/3`.

   Applies the full external-content pipeline in this exact order
   (FI-GH-039): stamp `source: :github`, `scrub/1`,
   `stamp_author_trust(actor: actor)`, `put_comment_message/1`. Every
   GitHub event producer must publish through this single entry point so
   no call site can skip or reorder the injection-safety steps.
   """
   @spec github_payload(map(), String.t() | nil) :: map()
   def github_payload(payload, actor) when is_map(payload) do
     payload
     |> Map.put(:source, :github)
     |> scrub()
     |> stamp_author_trust(actor: actor)
     |> put_comment_message()
   end
   ```

4. Migrate `src/lib/aiur/events/ls_remote_ticker.ex` onto the skeleton. Exact
   edits, nothing else — the `@moduledoc`, `@default_interval_ms 30_000`,
   `@default_remote`, `@default_ref_pattern`, `start_link/1` (kept as-is; it
   overrides the injected default), `init/1` state map, and every function not
   named below stay byte-identical:

   a. Replace `use GenServer` (line 28) with `use Aiur.PeriodicWorker`.
   b. Delete `alias Aiur.Alerts` (line 32) — after step 4f nothing in this
      module calls Alerts.
   c. In `init/1`, replace the last two lines
      (`unless state.start_paused?, do: schedule_tick(state.interval_ms)` and
      `{:ok, state}`) with the single line
      `{:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}`.
   d. Delete both `handle_info` clauses (lines 87-95) and `schedule_tick/1`
      (lines 97-99). The injected skeleton replaces them; note the injected
      `:tick` clause schedules from `:next_delay_ms`, exactly as the deleted
      clause did.
   e. Rename `defp run_tick(state)` to the public behaviour callback and drop
      its `rescue`/`catch` blocks (lines 126-135 — crash isolation now lives in
      `Aiur.PeriodicWorker.run_tick/2`, which logs the identical
      `"LsRemoteTicker tick raised: ..."` / `"LsRemoteTicker tick caught ..."`
      messages because the label is the module's last segment). Keep the
      10-line comment above it (lines 101-110) verbatim. The result:

      ```elixir
      @impl Aiur.PeriodicWorker
      @spec tick(map()) :: map()
      def tick(state) do
        case state.ls_remote_fun.(state.remote, [state.ref_pattern]) do
          {:ok, refs} when is_map(refs) ->
            state
            |> note_connectivity_success()
            |> fold_refs(refs)

          {:error, reason} ->
            Logger.debug("LsRemoteTicker poll failed: #{inspect(reason)}")
            note_connectivity_failure(state, Connectivity.classify_ls_remote(reason))

          other ->
            Logger.warning("LsRemoteTicker unexpected ls_remote result: #{inspect(other)}")
            state
        end
      end
      ```

   f. Replace `note_connectivity_failure/2` (lines 147-169) with the delegation
      below, and delete `connectivity_streak_count/1` (lines 171-176) and
      `normalize_backoff_ms/2` (lines 178-183) — that logic now lives only in
      `Connectivity`. Keep the 2-line comment above `note_connectivity_failure`
      verbatim. `note_connectivity_success/1` is untouched.

      ```elixir
      defp note_connectivity_failure(state, classification) do
        {streaks, delay_ms} =
          Connectivity.record_failure(
            state.connectivity,
            :ls_remote,
            classification,
            state.interval_ms,
            repo: state.repo || resolve_repo()
          )

        %{state | connectivity: streaks, next_delay_ms: delay_ms}
      end
      ```

      (Behavior check: the old code also resolved `state.repo || resolve_repo()`
      unconditionally on every failure tick, computed the streak count with the
      same `{_classification, count} when count > 0`-else-1 match, and
      normalized `:escalate` → `Connectivity.max_backoff_ms()` / non-integer →
      `state.interval_ms`. Identical.)

5. Migrate `src/lib/aiur/events/github_firehose.ex`: replace
   `do_publish_one/2` (lines 165-191) with the version below. The inline
   pipeline and its 8-line explanatory comment are replaced by the single
   `github_payload` call (the comment's content now lives in
   `Sanitizer.github_payload/2`'s `@doc`). The `rescue` clause and everything
   else in the file stay byte-identical.

   ```elixir
   defp do_publish_one(event, opts) do
     case translate(event, opts) do
       nil ->
         :ignored

       {topic, payload, publish_opts} ->
         sanitized = Sanitizer.github_payload(payload, Keyword.get(publish_opts, :actor))
         Publisher.publish(topic, sanitized, publish_opts)
     end
   rescue
     error ->
       Logger.warning("GithubFirehose publish failed: #{Exception.message(error)}")
       :ignored
   end
   ```

6. Migrate `src/lib/aiur/events/github_comments_poller.ex`: replace
   `publish_comment/4` (lines 298-312) with:

   ```elixir
   defp publish_comment(topic, payload, actor, publish_opts) do
     sanitized = Sanitizer.github_payload(payload, actor)

     publish_opts =
       publish_opts
       |> Keyword.put(:actor, actor)
       |> Keyword.put(:bypass_contamination, true)

     Publisher.publish(topic, sanitized, publish_opts)
   end
   ```

   Everything else in the file stays byte-identical — in particular the
   `@default_max_concurrency 4` / `@default_target_timeout 60_000` task
   settings, the `Task.Supervisor.async_stream_nolink` /
   trap-exit-fallback block (`target_task_results/4`), the workpad filtering
   call sites, dedup-key construction, and `advance_since/2`'s
   `DateTime.add(-1, :second)` overlap.

7. Create `src/test/aiur/periodic_worker_test.exs` with EXACTLY this content:

   ```elixir
   defmodule Aiur.PeriodicWorkerTest do
     use ExUnit.Case, async: true

     import ExUnit.CaptureLog

     defmodule TestWorker do
       use Aiur.PeriodicWorker

       @impl GenServer
       def init(opts) do
         state = %{
           interval_ms: Keyword.get(opts, :interval_ms, 25),
           start_paused?: Keyword.get(opts, :start_paused?, true),
           notify: Keyword.fetch!(opts, :notify),
           tick_fun: Keyword.fetch!(opts, :tick_fun)
         }

         {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
       end

       @impl Aiur.PeriodicWorker
       def tick(state), do: state.tick_fun.(state)
     end

     defp start_worker(opts) do
       opts = Keyword.put_new(opts, :notify, self())
       start_supervised!({TestWorker, opts})
     end

     test "start_paused?: true schedules no first tick" do
       tick_fun = fn state ->
         send(state.notify, :tick_ran)
         state
       end

       start_worker(start_paused?: true, tick_fun: tick_fun)
       refute_receive :tick_ran, 200
     end

     test "start_paused?: false ticks and reschedules from next_delay_ms" do
       tick_fun = fn state ->
         send(state.notify, :tick_ran)
         Map.put(state, :next_delay_ms, 10)
       end

       start_worker(start_paused?: false, interval_ms: 10, tick_fun: tick_fun)

       assert_receive :tick_ran, 2000
       assert_receive :tick_ran, 2000
     end

     test "a raising tick logs, keeps state, and keeps the schedule alive" do
       tick_fun = fn state ->
         send(state.notify, :tick_ran)
         raise "boom"
       end

       pid = start_worker(start_paused?: true, interval_ms: 10, tick_fun: tick_fun)

       log =
         capture_log(fn ->
           send(pid, :tick)
           assert_receive :tick_ran, 2000
           # the rescued tick still rescheduled: the next tick arrives
           assert_receive :tick_ran, 2000
         end)

       assert log =~ "TestWorker tick raised: boom"
     end

     test "a throwing tick is caught and logged" do
       tick_fun = fn state ->
         send(state.notify, :tick_ran)
         throw(:boom)
       end

       pid = start_worker(start_paused?: true, tick_fun: tick_fun)

       log =
         capture_log(fn ->
           send(pid, :tick)
           assert_receive :tick_ran, 2000
         end)

       assert log =~ "TestWorker tick caught throw: :boom"
     end

     test "unknown messages are ignored without crashing" do
       tick_fun = fn state -> state end
       pid = start_worker(start_paused?: true, tick_fun: tick_fun)

       send(pid, :unexpected)

       assert %{start_paused?: true} = :sys.get_state(pid)
     end
   end
   ```

8. Append to `src/test/aiur/github/connectivity_test.exs` (inside the existing
   top-level module, after the existing tests) two new describe blocks —
   `describe "record_failure/5"` and `describe "streak_count/2"` — with exactly
   these five tests (bodies as specified):

   - `"returns updated streaks and exponential backoff without emitting below threshold"`:
     `emit_fun` sends `{:alert, name, message, opts}` to `self()`; call
     `Connectivity.record_failure(%{}, :ls_remote, :dns, 30_000, emit_fun: emit_fun)`;
     assert the result is `{%{ls_remote: {:dns, 1}}, 1_000}` and
     `refute_receive {:alert, _, _, _}, 100`.
   - `"emits system.github.connectivity_lost exactly once when a dns streak crosses the threshold"`:
     thread the streak map through three `record_failure` calls with `:dns`,
     `30_000`, `emit_fun:` capturing to `self()`, `repo: "o/r"`. After call 2:
     `refute_received {:alert, _, _, _}`. After call 3:
     `assert_receive {:alert, "system.github.connectivity_lost", message, opts}, 2000`,
     then assert `message =~ "DNS resolution failures"`, `message =~ " for o/r"`,
     `opts[:needs_attention] == true`, `opts[:severity] == "warning"`,
     `opts[:reason] == message`. A fourth call emits nothing
     (`refute_received {:alert, _, _, _}`).
   - `":auth normalizes :escalate to max_backoff_ms"`: with a no-op `emit_fun`,
     `record_failure(%{}, :ls_remote, :auth, 30_000, ...)` returns delay
     `Connectivity.max_backoff_ms()`.
   - `"streak_count/2 returns the recorded count"`:
     `Connectivity.streak_count(%{ls_remote: {:dns, 4}}, :ls_remote) == 4`.
   - `"streak_count/2 defaults to 1 for unknown sources"`:
     `Connectivity.streak_count(%{}, :ls_remote) == 1`.

9. Append to `src/test/aiur/events/sanitizer_test.exs` a
   `describe "github_payload/2"` block with exactly two tests:

   - `"applies stamp-scrub-trust-message in order"`: build
     `payload = %{comment: %{"body" => "hello ghp_" <> String.duplicate("a", 36)}}`,
     call `Sanitizer.github_payload(payload, "octocat")`, assert
     `sanitized.source == :github`,
     `sanitized.comment["body"] =~ "[REDACTED:ghp]"`,
     `sanitized.author_trusted? == false`, and
     `sanitized.message == sanitized.comment["body"]` (proves
     `put_comment_message` ran after `scrub`).
   - `"stamps author_trusted? false for nil actor"`:
     `Sanitizer.github_payload(%{}, nil)` has `source == :github` and
     `author_trusted? == false`.

10. Run `mix format` from `src/`, then the full Agent gate. Do NOT add
    `Aiur.PeriodicWorker` (or anything else) to the `ignore_modules` list in
    `src/mix.exs` — new modules are not coverage-exempt; the 85% threshold
    enforces their tests.

Timing/concurrency semantics that must survive verbatim (the research docs'
risk list; hotspot #1 themes 1 and 10): tick re-scheduling happens AFTER the
tick body completes (never overlapping ticks) and always fires even when the
tick raises; error ticks never set `bootstrapped?` (no phantom-push storm,
FI-EVT-031/FI-GH-049); the connectivity alert fires exactly once at streak
count == 3 and success re-arms it (FI-GH-051); `:escalate` caps at 60s;
per-target comment polling keeps `async_stream_nolink` with max_concurrency 4,
60s `:kill_task` timeout, the trap-exit fallback, and in-order result zipping
(FI-GH-057); since-cursors advance only on zero-error polls, minus 1s overlap
(FI-GH-058); `bypass_contamination: true` on every comment publish
(FI-GH-055); workpad filtering only on the two issue-comment paths
(FI-GH-059); firehose watermark/backfill and pre-boot drop unchanged
(FI-GH-042/043).

## Files

- Create: `src/lib/aiur/periodic_worker.ex`,
  `src/test/aiur/periodic_worker_test.exs`
- Modify: `src/lib/aiur/events/ls_remote_ticker.ex`,
  `src/lib/aiur/events/github_firehose.ex`,
  `src/lib/aiur/events/github_comments_poller.ex`,
  `src/lib/aiur/github/connectivity.ex`,
  `src/lib/aiur/events/sanitizer.ex`
- Test: `src/test/aiur/periodic_worker_test.exs` (new),
  `src/test/aiur/github/connectivity_test.exs` (append only),
  `src/test/aiur/events/sanitizer_test.exs` (append only)

## Out of scope

- `src/lib/aiur/orchestrator.ex` — its duplicate connectivity fold
  (`note_github_connectivity_failure` etc., lines 1432-1519) and its split
  sanitize sites (lines 1612-1616, 1770-1775) migrate in the orchestrator
  decomposition wave (T-024/T-025). Do not touch the file.
- `src/lib/aiur/progress_checkin/worker.ex`, `src/lib/aiur/logs/retention.ex`,
  `src/lib/aiur/agent_resource_guard.ex` — the other cluster-1 GenServers
  adopt `Aiur.PeriodicWorker` in their own waves, not here.
- `src/lib/aiur/events/publisher.ex` — do NOT add `publish_external` or touch
  the fire-and-forget hot path (FI-EVT-002).
- `src/lib/aiur/events/github_keys.ex` — dedup keys are already centralized;
  no changes.
- `src/lib/aiur/github/client.ex`, `src/lib/aiur/events/comment_filter.ex`,
  `src/lib/aiur/events/pr_command_scanner.ex` — untouched.
- The existing test files `src/test/aiur/events/ls_remote_ticker_test.exs`,
  `github_firehose_test.exs`, `github_comments_poller_test.exs`,
  `github_keys_test.exs`, `sanitizer_test.exs` existing tests, and
  `connectivity_test.exs` existing tests — they pin current behavior and must
  pass UNMODIFIED (steps 8-9 append new tests only).
- Everything under `src/test/aiur/regression/`.
- Any change to tick cadence, dedup keys, cutoff, backoff, or alert constants
  (`@default_interval_ms`, `@repo_events_per_page`, `@max_event_pages`,
  `@default_max_concurrency`, `@default_target_timeout`,
  `@escalation_threshold`, `@base_backoff_ms`, `@max_backoff_ms`).
- Supervision-tree changes in `src/lib/aiur.ex`.

## Inventory-IDs

This ticket's files implement/touch (behavior must be preserved for all):

- `ls_remote_ticker.ex`: FI-EVT-030, FI-EVT-031, FI-EVT-032, FI-EVT-033
  (ticker side), FI-EVT-035, FI-EVT-036, FI-EVT-037, FI-EVT-038; FI-GH-048,
  FI-GH-049, FI-GH-050, FI-GH-053 (integration surface).
- `github_firehose.ex`: FI-EVT-033, FI-EVT-039, FI-EVT-040; FI-GH-039,
  FI-GH-040 (firehose side), FI-GH-041, FI-GH-042, FI-GH-043, FI-GH-044.
- `github_comments_poller.ex`: FI-EVT-041, FI-EVT-042; FI-GH-038 (consumer),
  FI-GH-039, FI-GH-055, FI-GH-056, FI-GH-057, FI-GH-058, FI-GH-059,
  FI-GH-060, FI-GH-061.
- `connectivity.ex`: FI-GH-051, FI-GH-052, FI-GH-053, FI-GH-054; FI-EVT-036.
- `sanitizer.ex`: FI-GH-038, FI-GH-039.

## Characterization-tests

All files under `src/test/aiur/regression/` must pass UNMODIFIED. The ones
protecting this area:

- `src/test/aiur/regression/event_flow_e2e_test.exs` (exists today — pins the
  publish → subscription → digest flow for `ticket.<id>.branch.push` and
  `ticket.<id>.issue.commented`).
- The GitHub-ingestion characterization files added by T-008
  (Characterization: GitHub ingestion & wake/rework): dedup keys, boot cutoffs
  (boot − 60s), workpad filtering, per-target isolation, backoff wiring — per
  `research-history-hotspots.md` "Densest characterization coverage" item 2.
  Run `ls src/test/aiur/regression/` before starting and treat every file
  there as read-only.

## Acceptance criteria

- `src/lib/aiur/periodic_worker.ex` exists;
  `grep -c "defmodule Aiur.PeriodicWorker do" src/lib/aiur/periodic_worker.ex`
  = 1; `grep -c "" src/lib/aiur/periodic_worker.ex` <= 200.
- `src/test/aiur/periodic_worker_test.exs` exists with 5 tests
  (`grep -c "    test \"" src/test/aiur/periodic_worker_test.exs` = 5, or
  equivalent count of `test "` occurrences = 5).
- `grep -n "PeriodicWorker" src/mix.exs` → no matches (new module is NOT
  coverage-exempt; `mix test --cover` meets the 85% threshold).
- Skeleton fully removed from the ticker:
  `grep -cE "def handle_info|Process\.send_after|defp schedule_tick" src/lib/aiur/events/ls_remote_ticker.ex` = 0;
  `grep -cE "rescue|catch" src/lib/aiur/events/ls_remote_ticker.ex` = 0.
- Connectivity fold removed from the ticker:
  `grep -cE "connectivity_streak_count|normalize_backoff_ms|emit_custom|Aiur.Alerts" src/lib/aiur/events/ls_remote_ticker.ex` = 0;
  `grep -c "Connectivity.record_failure" src/lib/aiur/events/ls_remote_ticker.ex` = 1.
- `grep -c "use Aiur.PeriodicWorker" src/lib/aiur/events/ls_remote_ticker.ex` = 1;
  `grep -c "def tick(state)" src/lib/aiur/events/ls_remote_ticker.ex` = 1.
- Sanitize pipeline has one home:
  `grep -c "Sanitizer.github_payload" src/lib/aiur/events/github_firehose.ex` = 1;
  `grep -c "Sanitizer.github_payload" src/lib/aiur/events/github_comments_poller.ex` = 1;
  `grep -cE "stamp_author_trust|put_comment_message|Map\.put\(:source, :github\)" src/lib/aiur/events/github_firehose.ex src/lib/aiur/events/github_comments_poller.ex` reports 0 for both files;
  `grep -c "def github_payload" src/lib/aiur/events/sanitizer.ex` = 1.
- `grep -c "def record_failure" src/lib/aiur/github/connectivity.ex` = 1;
  `grep -c "def streak_count" src/lib/aiur/github/connectivity.ex` = 1.
- Parent file line counts reduced: `wc -l src/lib/aiur/events/ls_remote_ticker.ex`
  < 235 (was 262); `wc -l src/lib/aiur/events/github_firehose.ex` < 245
  (was 249); `wc -l src/lib/aiur/events/github_comments_poller.ex` < 376
  (was 376).
- Byte-identical cadence/backoff/dedup constants:
  `grep -c "@default_interval_ms 30_000" src/lib/aiur/events/ls_remote_ticker.ex` = 1;
  `grep -c "@repo_events_per_page 30" src/lib/aiur/events/github_firehose.ex` = 1;
  `grep -c "@max_event_pages 5" src/lib/aiur/events/github_firehose.ex` = 1;
  `grep -c "@default_max_concurrency 4" src/lib/aiur/events/github_comments_poller.ex` = 1;
  `grep -c "@default_target_timeout 60_000" src/lib/aiur/events/github_comments_poller.ex` = 1;
  `grep -c "DateTime.add(-1, :second)" src/lib/aiur/events/github_comments_poller.ex` = 1;
  `grep -c "pre_boot_event?" src/lib/aiur/events/github_firehose.ex` = 1;
  `grep -c "@escalation_threshold 3" src/lib/aiur/github/connectivity.ex` = 1;
  `grep -c "@max_backoff_ms 60_000" src/lib/aiur/github/connectivity.ex` = 1.
- Every new/changed public def carries `@spec` and every new module has
  `@moduledoc` (`mix specs.check` — run via `mix lint` — passes).
- New file <= 200 lines; no new function exceeds 20 logic lines (the longest,
  `Connectivity.record_failure/5`, is ~15).
- Full suite green including all of `src/test/aiur/regression/` unmodified:
  `git diff --name-only origin/v2...HEAD | grep '^src/test/aiur/regression/'`
  outputs nothing.
- `git diff --name-only origin/v2...HEAD` lists exactly the 8 files in the
  Files section (2 created, 5 modified lib files, 2 modified test files, 1
  created test file — 8 paths total).

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

- Check (FI-GH-051, adapted from the FI-EVT-068 probe pattern): in
  `iex -S mix` from `src/`, run
  `Aiur.Events.Exchange.subscribe("system.github.connectivity_lost")`, then
  `{s, d} = Aiur.GitHub.Connectivity.record_failure(%{}, :probe, :dns, 30_000, [])`
  three times threading `s` through; exactly one
  `{:event, %{source: "alert", needs_attention: true}}` message arrives, on
  the third call, and `d == 1000/2000/4000` across the calls. A fourth call
  delivers no second event; after
  `Aiur.GitHub.Connectivity.note_success(s, :probe)` three more `:dns`
  failures re-emit exactly once.
- Check (FI-GH-039): read `Sanitizer.github_payload/2` and confirm the body
  is exactly the four steps in order
  `Map.put(:source, :github) |> scrub() |> stamp_author_trust(actor: actor) |> put_comment_message()`,
  and that both poller call sites pass the same actor they put in
  `publish_opts`.
- Check (verbatim move): diff `LsRemoteTicker.tick/1` against the pre-change
  `run_tick/1` body (`git show origin/v2:src/lib/aiur/events/ls_remote_ticker.ex`)
  — the `case` body is byte-identical; only the `rescue`/`catch` moved.
- Check (FI-EVT-031/FI-GH-049 spot-check): `cd src && mix test test/aiur/events/ls_remote_ticker_test.exs`
  green with zero test-file changes (`git diff origin/v2...HEAD -- src/test/aiur/events/` shows only appended
  `describe` blocks in `sanitizer_test.exs`, none in `ls_remote_ticker_test.exs`).
- Check (FI-GH-057): confirm `target_task_results/4` in the poller diff is
  untouched (no hunk covers it).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
