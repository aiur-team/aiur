defmodule Aiur.Orchestrator.CommentPolling do
  @moduledoc """
  GitHub firehose and comments poll drivers.

  The firehose poll runs inside the orchestrator GenServer process. The comments
  poll does not: it fans out over every watched target, and the Orchestrator
  awaiting that fan-out inline is what left it unreadable on an idle host
  (#1837). `start_async/2` issues it and `apply_async/3` folds the answer in.
  `poll_github_comments/2` still does both in one step for callers that want the
  synchronous shape.
  """

  require Logger

  alias Aiur.{AlertFeed, Alerts, Config, PollCadence, RunTelemetry}
  alias Aiur.Events.{GithubCommentsPoller, GithubFirehose}
  alias Aiur.GitHub.CommentPollBatch
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling.TargetSelection
  alias Aiur.Orchestrator.State

  @recent_merge_persistence_retry_limit 3

  # Consecutive firehose ticks that truncate (reach `@events_window_pages`
  # without finding the previous watermark) before the sustained-truncation
  # attention fires. One truncated tick can be a boot reconciliation or a
  # one-off burst; two in a row means truncation is the steady state and the
  # Executor must hear about it (#2354).
  @firehose_truncation_threshold 2

  @comment_poll_setup_timeout_ms 300_000
  @comment_poll_abandon_margin_ms 30_000

  @spec poll_github_firehose(State.t(), keyword()) :: State.t()
  def poll_github_firehose(%State{} = state, opts \\ []) do
    poll_opts =
      opts
      |> Keyword.put_new(:etag, state.events_etag)
      |> Keyword.put_new(:last_event_id, state.events_last_id)

    case GithubFirehose.poll(poll_opts) do
      {:ok, %{etag: etag, last_event_id: last_event_id} = result} ->
        state =
          state
          |> Orchestrator.note_github_connectivity_success(:firehose)
          |> Orchestrator.note_github_poll_interval(:firehose, Map.get(result, :poll_interval))
          |> note_recent_merge_persistence_success(Map.get(result, :recent_merge_persistence))
          |> note_firehose_window(result, opts)

        %{state | events_etag: etag, events_last_id: last_event_id}

      {:error, {:recent_merge_persistence, reason, cursor}} ->
        note_recent_merge_persistence_failure(state, reason, cursor, opts)

      {:error, reason} ->
        # Preserve cached etag so we retry as If-None-Match next tick; the
        # classified failure feeds the escalation policy so a sustained
        # DNS/auth break surfaces a loud Executor blocker (#617).
        Orchestrator.note_github_connectivity_failure(state, :firehose, reason)
    end
  end

  defp note_recent_merge_persistence_success(state, :ok) do
    Orchestrator.note_github_connectivity_success(state, :recent_merge_store)
  end

  defp note_recent_merge_persistence_success(state, _status), do: state

  # The firehose window metric (#2354). Every successful tick records how many
  # event pages were fetched and whether the previous watermark was reachable
  # inside GitHub's events window. `partial?` is true only when the poll hit
  # `@events_window_pages` without finding the watermark — events beyond the
  # window were genuinely lost, not merely skipped — and is the signal the
  # sustained-truncation attention keys on.
  defp note_firehose_window(state, result, opts) do
    partial? = Map.get(result, :partial_window?, false)
    pages_fetched = Map.get(result, :pages_fetched, 0)
    published = Map.get(result, :count, 0)

    Logger.info("aiur_perf github_firehose pages=#{pages_fetched} capped=#{partial?} published=#{published}")

    telemetry_fun = Keyword.get(opts, :firehose_poll_telemetry_fun, &RunTelemetry.record/2)

    _ =
      telemetry_fun.(:firehose_poll, %{
        pages_fetched: pages_fetched,
        partial_window?: partial?,
        published: published
      })

    streak = if partial?, do: state.firehose_partial_streak + 1, else: 0
    state = %{state | firehose_partial_streak: streak}
    reconcile_firehose_truncation_alert(state, partial?, streak, opts)
  end

  # Fires the attention once a truncated window becomes the steady state, and
  # resolves it the first tick the window is complete again. Mirrors the
  # dispatcher's prewarm-blocked alert lifecycle.
  #
  # The resolve decision reads both the in-memory latch and the durable alert
  # feed: after an Orchestrator restart the in-memory flag is lost while the
  # feed still carries the attention, so a complete window must still clear it.
  defp reconcile_firehose_truncation_alert(%State{} = state, false, _streak, opts) do
    resolve? =
      state.firehose_truncation_alert_active or
        AlertFeed.active_system_attention?("system.firehose.event_truncation")

    if resolve?, do: resolve_firehose_truncation_alert(state, opts), else: state
  end

  defp reconcile_firehose_truncation_alert(state, true, streak, opts) when streak >= @firehose_truncation_threshold,
    do: arm_firehose_truncation_alert(state, opts)

  defp reconcile_firehose_truncation_alert(state, _partial?, _streak, _opts), do: state

  defp arm_firehose_truncation_alert(%State{firehose_truncation_alert_active: true} = state, _opts), do: state

  defp arm_firehose_truncation_alert(%State{} = state, opts) do
    reason =
      "The GitHub repo-events firehose hit its #{GithubFirehose.events_window_pages()} page bound on " <>
        "#{state.firehose_partial_streak} consecutive ticks without reaching the previous event watermark. " <>
        "Events beyond GitHub's #{GithubFirehose.events_window_pages() * GithubFirehose.repo_events_per_page()}-event " <>
        "window are being dropped each tick; the firehose is truncating an unbounded stream."

    case firehose_truncation_alert_fun(opts).("system.firehose.event_truncation",
           reason: reason,
           needs_attention: true,
           severity: "warning"
         ) do
      :ok -> %{state | firehose_truncation_alert_active: true, firehose_truncation_alert_resolution_emitted: false}
      {:error, _reason} -> state
    end
  end

  defp resolve_firehose_truncation_alert(%State{firehose_truncation_alert_resolution_emitted: true} = state, _opts),
    do: %{state | firehose_truncation_alert_active: false}

  defp resolve_firehose_truncation_alert(%State{} = state, opts) do
    _ =
      firehose_truncation_alert_fun(opts).("system.firehose.event_truncation.resolved",
        reason: "The GitHub repo-events firehose returned a complete event window; the truncation attention clears.",
        needs_attention: false,
        severity: "info"
      )

    %{state | firehose_truncation_alert_active: false, firehose_truncation_alert_resolution_emitted: true}
  end

  defp firehose_truncation_alert_fun(opts) do
    Keyword.get(opts, :firehose_truncation_alert_fun, &Alerts.emit_system/2)
  end

  defp note_recent_merge_persistence_failure(state, reason, cursor, opts) do
    failures = recent_merge_persistence_failure_count(state) + 1
    retry_limit = recent_merge_persistence_retry_limit(opts)
    advance? = failures >= retry_limit

    Logger.warning("GithubFirehose local outcome persistence failed; attempt=#{failures} advance=#{advance?} reason=#{inspect(reason)}")

    state =
      state
      |> Orchestrator.note_github_connectivity_success(:firehose)
      |> Orchestrator.note_github_poll_interval(:firehose, Map.get(cursor, :poll_interval))
      |> Orchestrator.note_github_connectivity_failure(:recent_merge_store, {:recent_merge_persistence, reason})
      |> maybe_alert_recent_merge_persistence(reason, retry_limit, opts)

    if advance? do
      %{
        state
        | events_etag: Map.get(cursor, :etag),
          events_last_id: Map.get(cursor, :last_event_id)
      }
    else
      state
    end
  end

  defp recent_merge_persistence_failure_count(state) do
    case Map.get(state.github_connectivity, :recent_merge_store) do
      {_classification, count} when is_integer(count) and count > 0 -> count
      _other -> 0
    end
  end

  defp recent_merge_persistence_retry_limit(opts) do
    case Keyword.get(opts, :recent_merge_persistence_retry_limit, @recent_merge_persistence_retry_limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @recent_merge_persistence_retry_limit
    end
  end

  defp maybe_alert_recent_merge_persistence(state, reason, limit, opts) do
    if recent_merge_persistence_failure_count(state) == limit do
      emit_recent_merge_persistence_alert(state, reason, opts)
    else
      state
    end
  end

  defp emit_recent_merge_persistence_alert(state, reason, opts) do
    failures = recent_merge_persistence_failure_count(state)

    message =
      "Recent repository merge audit remains read-only or unwritable after " <>
        "#{failures} attempts (#{inspect(reason)}). " <>
        "GitHub event delivery is continuing without durable outcome records until storage recovers."

    alert_fun = Keyword.get(opts, :recent_merge_alert_fun, &Alerts.emit_custom/3)

    _ =
      alert_fun.("recent_merge_store.persistence_failed", message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )

    state
  rescue
    error ->
      Logger.warning("GithubFirehose local outcome persistence alert failed; reason=#{Exception.message(error)}")
      state
  catch
    kind, reason ->
      Logger.warning("GithubFirehose local outcome persistence alert failed; reason=#{inspect({kind, reason})}")
      state
  end

  @spec poll_github_comments(State.t(), keyword()) :: State.t()
  def poll_github_comments(%State{} = state, opts \\ []) do
    case Config.tracker_kind() do
      # Comment polling always runs at the configured cadence. #1384 scoped a
      # widen-on-quiet backoff, but it is deliberately not implemented: a global
      # quiet gate is inert whenever any agent is running (the case the rate
      # incident is about) and a per-target one would delay a new ticket's first
      # comment wake, which the ticket lists as a non-goal. The steady-state
      # saving comes from 304s and the GraphQL batch, not from skipping cycles.
      "github" ->
        do_poll_github_comments(state, opts)

      _ ->
        state
    end
  end

  defp do_poll_github_comments(%State{} = state, opts) do
    apply_comment_poll(state, run_comment_poll(state, opts))
  end

  @doc """
  Starts the comment poll on another process and returns immediately.

  The poll fans out over every watched target with `Task.async_stream` and the
  Orchestrator used to consume that stream inline from its dispatch callback:
  captured on an *idle* host (load 1.68, quota healthy) parked in
  `Task.Supervised.stream_reduce/7` under `do_maybe_dispatch/1` with 5,729
  messages queued behind it, while `aiur status` and `aiur agents` both timed
  out. A per-request deadline cannot bound that — awaiting N targets costs N
  deadlines — so the fetch leaves the callback entirely and comes back as
  `{:github_comments_polled, ref, payload}`, which `apply_async/3` folds in.

  One poll at a time: a second is not started while one is outstanding, or two
  fan-outs would race the same cursors. That skip is time-boxed rather than
  latched — a worker that dies without answering would otherwise silence comment
  polling for the life of the daemon, and silence is exactly what this poller
  exists to prevent.
  """
  @spec start_async(State.t(), keyword()) :: State.t()
  def start_async(%State{} = state, opts \\ []) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      tracker_kind(opts) != "github" -> state
      comment_poll_in_flight?(state, now_ms) -> state
      within_review_cadence?(state, now_ms) -> state
      true -> spawn_comment_poll(state, opts, now_ms)
    end
  end

  defp tracker_kind(opts), do: Keyword.get_lazy(opts, :tracker_kind, &Config.tracker_kind/0)

  # Throttles the comment poll to the `:review` class cadence (#2309). See
  # `PollCadence.within_class_cadence?/3` for the two limits that keep this a
  # no-op where it must be (never fired, or nothing published yet). The class
  # cadence is the safety-net price for a review poll that no longer runs at the
  # dispatch rate once an operator sets `intervals.review` wider — the tradeoff
  # #2309 exists to make, and webhooks cover the arrival of a comment in the
  # meantime.
  #
  # The divergence is *enforced*, not asserted: `TrackerHealth` publishes a
  # `:review` cadence wider than the dispatch tick only when the repo is proven
  # webhook-backed, so on a polling repo the published `:review` value equals
  # the dispatch cadence and this gate never binds — the safety net stays at the
  # dispatch rate. This is the "no webhook installed: nothing is ever
  # suppressed" contract (see `apis/github.md`).
  defp within_review_cadence?(state, now_ms) do
    PollCadence.within_class_cadence?(state.last_comment_poll_started_at_ms, now_ms, :review)
  end

  @doc """
  Folds a completed asynchronous comment poll into the current state.

  Results from an abandoned or superseded poll are dropped: the reference names
  the poll this state is waiting for, and anything else is a straggler whose
  cursors would move the fleet backwards.
  """
  @spec apply_async(State.t(), reference(), term()) :: State.t()
  def apply_async(%State{github_comment_poll: %{ref: ref} = poll} = state, ref, payload) do
    release_poll_owner(poll)
    demonitor_comment_poll(poll)
    state = %{state | github_comment_poll: nil}
    apply_comment_poll(state, payload)
  end

  def apply_async(%State{} = state, _stale_ref, _payload), do: state

  @doc false
  @spec apply_async_started(State.t(), reference(), pid(), pid()) :: State.t()
  def apply_async_started(%State{github_comment_poll: %{ref: ref, owner: owner} = pending} = state, ref, owner, pid) do
    monitor_ref = Process.monitor(pid)
    send(owner, {:start_owned_poll, self(), ref})

    poll =
      pending
      |> Map.put(:pid, pid)
      |> Map.put(:monitor_ref, monitor_ref)
      |> Map.put(:guarding?, false)

    %{state | github_comment_poll: poll}
  end

  def apply_async_started(%State{} = state, _stale_ref, owner, _pid) do
    stop_ref = make_ref()
    send(owner, {:stop_owned_poll, self(), stop_ref})
    state
  end

  @doc false
  @spec apply_async_guarding(State.t(), reference(), pid(), pid()) :: State.t()
  def apply_async_guarding(
        %State{github_comment_poll: %{ref: ref, owner: owner, pid: pid} = poll} = state,
        ref,
        owner,
        pid
      ) do
    %{state | github_comment_poll: Map.put(poll, :guarding?, true)}
  end

  def apply_async_guarding(%State{} = state, _stale_ref, owner, _pid) do
    send(owner, {:stop_owned_poll, self(), make_ref()})
    state
  end

  @doc false
  @spec apply_async_down(State.t(), reference()) :: {:handled, State.t()} | :unhandled
  def apply_async_down(
        %State{github_comment_poll: %{owner_monitor_ref: owner_monitor_ref} = poll} = state,
        owner_monitor_ref
      ) do
    reap_poll_after_owner_down(poll)
    {:handled, %{state | github_comment_poll: nil}}
  end

  def apply_async_down(%State{github_comment_poll: %{monitor_ref: monitor_ref} = poll} = state, monitor_ref) do
    release_poll_owner(poll)
    demonitor_owner(poll)
    {:handled, %{state | github_comment_poll: nil}}
  end

  def apply_async_down(%State{}, _stale_monitor_ref), do: :unhandled

  defp comment_poll_in_flight?(
         %State{github_comment_poll: %{started_at_ms: started_at_ms, abandon_after_ms: abandon_after_ms}} = state,
         now_ms
       )
       when is_integer(started_at_ms) and is_integer(abandon_after_ms) do
    if now_ms - started_at_ms < abandon_after_ms do
      true
    else
      Logger.warning(
        "GithubCommentsPoller poll has not answered in #{abandon_after_ms}ms; " <>
          "abandoning it and starting a fresh one"
      )

      abandon_poll(state.github_comment_poll)
      false
    end
  end

  defp comment_poll_in_flight?(_state, _now_ms), do: false

  defp spawn_comment_poll(%State{} = state, opts, now_ms) do
    orchestrator = self()
    ref = make_ref()

    task_fun = fn -> send(orchestrator, {:github_comments_polled, ref, run_comment_poll(state, opts)}) end
    phase_hook = Keyword.get(opts, :owner_phase_hook)
    {owner, owner_monitor_ref} = spawn_owned_poll(orchestrator, state.snapshot_key, ref, task_fun, phase_hook)
    abandon_after_ms = comment_poll_abandon_after_ms(state, opts)

    poll = %{ref: ref, owner: owner, owner_monitor_ref: owner_monitor_ref, started_at_ms: now_ms, abandon_after_ms: abandon_after_ms}
    %{state | github_comment_poll: poll, last_comment_poll_started_at_ms: now_ms}
  end

  defp comment_poll_abandon_after_ms(state, opts) do
    target_count = TargetSelection.max_comment_poll_target_count(state, opts)

    comment_poll_setup_timeout_ms(opts) +
      GithubCommentsPoller.max_duration_ms(target_count, opts) +
      @comment_poll_abandon_margin_ms
  end

  defp comment_poll_setup_timeout_ms(opts) do
    case Keyword.get(opts, :setup_timeout, @comment_poll_setup_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> @comment_poll_setup_timeout_ms
    end
  end

  defp abandon_poll(%{owner: owner} = poll) when is_pid(owner) do
    # Stop is synchronous: if the owner's DOWN is queued behind the dispatch
    # callback that noticed expiry, merely sending to it and flushing monitors
    # would discard the only evidence needed to reap its poll before replacement.
    terminate_poll(poll)
    demonitor_comment_poll(poll)
  end

  defp abandon_poll(_poll), do: :ok

  @doc false
  @spec terminate_poll(map() | nil) :: :ok
  def terminate_poll(%{pid: pid, owner: owner, monitor_ref: monitor_ref})
      when is_pid(pid) and is_pid(owner) and is_reference(monitor_ref) do
    stop_ref = make_ref()
    owner_ref = Process.monitor(owner)
    send(owner, {:stop_owned_poll, self(), stop_ref})

    receive do
      {:owned_poll_stopped, ^stop_ref} ->
        Process.demonitor(owner_ref, [:flush])

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> Process.demonitor(monitor_ref, [:flush])
        end

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        # A completed poll owner can exit before the Orchestrator consumes its
        # result. If it died unexpectedly while the poll remains alive, reap
        # the tree here rather than hanging shutdown on a message to a dead pid.
        if Process.alive?(pid) do
          reap_process_tree(pid, monitor_ref)
        else
          Process.demonitor(monitor_ref, [:flush])
        end
    end

    :ok
  end

  def terminate_poll(%{owner: owner}) when is_pid(owner) do
    stop_ref = make_ref()
    owner_ref = Process.monitor(owner)
    send(owner, {:stop_owned_poll, self(), stop_ref})

    receive do
      {:owned_poll_stopped, ^stop_ref} -> Process.demonitor(owner_ref, [:flush])
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
    end

    :ok
  end

  def terminate_poll(_poll), do: :ok

  # The poll temporarily traps exits while Task.async_stream owns its target
  # tasks, so a link is not an inverse lifetime edge. The owner monitors the
  # Orchestrator, and the Orchestrator retains its owner monitor through the
  # acknowledged guarding handoff; either side's death therefore reaps the poll.
  defp spawn_owned_poll(orchestrator, ownership_key, ref, task_fun, phase_hook) do
    spawn_monitor(fn ->
      orchestrator_ref = Process.monitor(orchestrator)

      case claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref) do
        :ok ->
          {poll, poll_ref} = spawn_monitor(fn -> receive do: (:start -> task_fun.()) end)
          send(orchestrator, {:github_comment_poll_started, ref, self(), poll})
          await_poll_start(orchestrator, orchestrator_ref, ref, poll, poll_ref, phase_hook)

        :orchestrator_down ->
          :ok

        {:stop, caller, stop_ref} ->
          send(caller, {:owned_poll_stopped, stop_ref})
      end
    end)
  end

  defp await_poll_start(orchestrator, orchestrator_ref, ref, poll, poll_ref, phase_hook) do
    receive do
      {:start_owned_poll, ^orchestrator, ^ref} ->
        run_owner_phase_hook(phase_hook, :before_start, poll)
        send(poll, :start)
        run_owner_phase_hook(phase_hook, :after_start_before_guard, poll)
        send(orchestrator, {:github_comment_poll_guarding, ref, self(), poll})
        guard_poll_lifetime(orchestrator, orchestrator_ref, poll, poll_ref)

      {:stop_owned_poll, caller, stop_ref} ->
        reap_process_tree(poll, poll_ref)
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        reap_process_tree(poll, poll_ref)
    end
  end

  defp claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref) do
    key = {:github_comment_poll, ownership_key}

    case Registry.register(Aiur.Events.SubscriptionStoreRegistry, key, nil) do
      {:ok, _value} ->
        :ok

      {:error, {:already_registered, owner}} ->
        owner_ref = Process.monitor(owner)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref)

          {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
            Process.demonitor(owner_ref, [:flush])
            :orchestrator_down

          {:stop_owned_poll, caller, stop_ref} ->
            Process.demonitor(owner_ref, [:flush])
            {:stop, caller, stop_ref}
        end
    end
  end

  defp guard_poll_lifetime(orchestrator, orchestrator_ref, poll, poll_ref) do
    receive do
      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        reap_process_tree(poll, poll_ref)

      {:stop_owned_poll, caller, stop_ref} ->
        reap_process_tree(poll, poll_ref)
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^poll_ref, :process, ^poll, _reason} ->
        await_poll_release(orchestrator, orchestrator_ref)
    end
  end

  defp await_poll_release(orchestrator, orchestrator_ref) do
    receive do
      {:release_owned_poll, ^orchestrator, _ref} ->
        Process.demonitor(orchestrator_ref, [:flush])

      {:stop_owned_poll, caller, stop_ref} ->
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        :ok
    end
  end

  defp run_owner_phase_hook(hook, phase, poll) when is_function(hook, 3), do: hook.(phase, self(), poll)
  defp run_owner_phase_hook(_hook, _phase, _poll), do: :ok

  defp release_poll_owner(%{owner: owner, ref: ref}) when is_pid(owner) and is_reference(ref) do
    send(owner, {:release_owned_poll, self(), ref})
  end

  defp release_poll_owner(_poll), do: :ok

  defp reap_poll_after_owner_down(%{pid: pid, monitor_ref: monitor_ref} = poll)
       when is_pid(pid) and is_reference(monitor_ref) do
    if Process.alive?(pid) do
      reap_process_tree(pid, monitor_ref)
    else
      Process.demonitor(monitor_ref, [:flush])
    end

    demonitor_owner(poll)
  end

  defp reap_poll_after_owner_down(poll), do: demonitor_owner(poll)

  defp demonitor_owner(%{owner_monitor_ref: owner_monitor_ref}) when is_reference(owner_monitor_ref) do
    Process.demonitor(owner_monitor_ref, [:flush])
  end

  defp demonitor_owner(_poll), do: :ok

  defp reap_process_tree(root, root_ref) do
    descendants = linked_descendants(root, MapSet.new([self()]))
    descendant_refs = Enum.map(descendants, &{&1, Process.monitor(&1)})
    Process.exit(root, :kill)
    await_process_down(root, root_ref)
    Enum.each(descendant_refs, fn {pid, ref} -> await_process_down(pid, ref) end)
  end

  defp linked_descendants(pid, seen) do
    links =
      case Process.info(pid, :links) do
        {:links, linked} -> Enum.filter(linked, &(is_pid(&1) and not MapSet.member?(seen, &1)))
        nil -> []
      end

    Enum.reduce(links, links, fn linked, descendants ->
      nested = linked_descendants(linked, Enum.reduce(descendants, MapSet.put(seen, pid), &MapSet.put(&2, &1)))
      Enum.uniq(descendants ++ nested)
    end)
  end

  defp await_process_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp demonitor_comment_poll(poll) when is_map(poll) do
    case Map.get(poll, :monitor_ref) do
      monitor_ref when is_reference(monitor_ref) -> Process.demonitor(monitor_ref, [:flush])
      _missing -> :ok
    end

    demonitor_owner(poll)
  end

  # The I/O half. Runs on whichever process the caller chose — never touches the
  # state it was handed, so its result can be folded into a newer one.
  defp run_comment_poll(%State{} = state, opts) do
    case run_comment_poll_setup(state, opts) do
      {:ok, cache, human_review_targets, targets, poll_opts} ->
        {:ok, cache, human_review_targets, poll_prepared_targets(targets, poll_opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Discovery, PR freshness, authorization timelines, pagination, and the
  # GraphQL batch can each issue a variable number of sequential requests. A
  # guessed request count cannot prove an outer lifetime bound, so setup owns
  # one explicit wall-clock budget instead. The worker is linked into the poll
  # tree, and timeout reaps its request descendants before returning.
  defp run_comment_poll_setup(%State{} = state, opts) do
    parent = self()
    result_ref = make_ref()
    timeout_ms = comment_poll_setup_timeout_ms(opts)
    previous_trap_exit = Process.flag(:trap_exit, true)

    {worker, worker_ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {__MODULE__, result_ref, prepare_comment_poll(state, opts)}) end,
        [:link, :monitor]
      )

    try do
      await_comment_poll_setup(worker, worker_ref, result_ref, timeout_ms)
    after
      Process.unlink(worker)
      flush_link_exit(worker)
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp await_comment_poll_setup(worker, worker_ref, result_ref, timeout_ms) do
    receive do
      {__MODULE__, ^result_ref, result} ->
        await_process_down(worker, worker_ref)
        result

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        exit({:comment_poll_setup_exit, reason})
    after
      timeout_ms ->
        Logger.warning("GithubCommentsPoller setup exceeded its #{timeout_ms}ms phase deadline and was abandoned")
        reap_process_tree(worker, worker_ref)
        flush_setup_result(result_ref)
        {:error, :setup_deadline_exceeded}
    end
  end

  defp flush_setup_result(result_ref) do
    receive do
      {__MODULE__, ^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_link_exit(worker) do
    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp prepare_comment_poll(%State{} = state, opts) do
    case TargetSelection.github_comment_poll_targets_with_cache(state, opts) do
      {:ok, targets, human_review_targets, watch_targets, cache} ->
        poll_opts = prepare_comment_poll_opts(state, targets, human_review_targets, watch_targets, opts)
        {:ok, cache, human_review_targets, targets, poll_opts}

      {:error, _reason} = error ->
        error
    end
  end

  # The fold half. Runs on the Orchestrator, against whatever state it holds now.
  defp apply_comment_poll(%State{} = state, {:ok, cache, human_review_targets, poll_outcome}) do
    state = %{state | github_comment_issue_list_cache: cache}
    apply_poll_outcome(state, human_review_targets, poll_outcome)
  end

  defp apply_comment_poll(%State{} = state, {:error, reason}) do
    Logger.warning("GithubCommentsPoller target refresh skipped; reason=#{inspect(reason)}")
    state
  end

  defp apply_comment_poll(%State{} = state, _unrecognised), do: state

  defp poll_prepared_targets([], _poll_opts), do: :no_targets

  defp poll_prepared_targets(targets, poll_opts) when is_list(targets) do
    {targets, GithubCommentsPoller.poll(targets, poll_opts)}
  end

  defp prepare_comment_poll_opts(%State{}, [], _human_review_targets, _watch_targets, opts), do: opts

  defp prepare_comment_poll_opts(%State{} = state, targets, human_review_targets, watch_targets, opts) when is_list(targets) do
    review_submission_targets = MapSet.new(human_review_targets, & &1.target)

    poll_opts =
      opts
      |> Keyword.put_new(:since, state.github_comments_since)
      |> Keyword.put_new(:etags, state.github_comment_etags)
      |> TargetSelection.put_open_pull_requests_by_target(human_review_targets)
      |> TargetSelection.put_open_pull_requests_by_target(watch_targets)
      |> Keyword.put_new(:titles_by_target, running_titles_by_target(state))
      |> Keyword.put(:review_submission_targets, review_submission_targets)
      |> Keyword.put(:pr_review_seen_at, state.pr_review_seen_at)

    put_comment_batch(poll_opts, targets)
  end

  defp apply_poll_outcome(%State{} = state, _human_review_targets, :no_targets), do: state

  defp apply_poll_outcome(%State{} = state, human_review_targets, {targets, poll_result}) do
    case poll_result do
      {:ok, %{since: since, etags: etags, count: count, errors: errors, pr_review_seen_at: new_review_seen_at}} ->
        if count > 0,
          do: Logger.debug("aiur_perf github_comments_poller published count=#{count}")

        if errors != [] do
          Logger.warning("GithubCommentsPoller partial failures; reason=#{inspect(errors)}")
        end

        state =
          if all_comment_targets_failed?(targets, errors) do
            Orchestrator.note_github_connectivity_failure(state, :comments, comments_poll_classification(errors))
          else
            Orchestrator.note_github_connectivity_success(state, :comments)
          end

        %{
          state
          | github_comments_since: TargetSelection.merge_comment_cursors(state.github_comments_since, since),
            github_comment_etags: Map.merge(state.github_comment_etags, etags),
            github_comment_issue_updated_at:
              TargetSelection.remember_polled_human_review_targets(
                state.github_comment_issue_updated_at,
                human_review_targets,
                errors
              ),
            pr_review_seen_at: Map.merge(state.pr_review_seen_at, new_review_seen_at)
        }
    end
  end

  # GitHub issues carry no branch name, so the comment batch derives each
  # running ticket's generated `aiur/<id>-<slug>` branch from its title. Without
  # this every target without an already-known PR guesses the legacy
  # `aiur/<id>` branch, misses, and falls back to the full REST fan-out.
  defp running_titles_by_target(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.reduce(%{}, fn entry, acc ->
      with identifier when is_binary(identifier) and identifier != "" <- Map.get(entry, :identifier),
           %{title: title} when is_binary(title) and title != "" <- Map.get(entry, :issue) do
        Map.put(acc, to_string(identifier), title)
      else
        _other -> acc
      end
    end)
  end

  defp put_comment_batch(opts, targets) do
    fetcher = Keyword.get(opts, :comment_batch_fetcher, &CommentPollBatch.fetch/2)

    case fetcher.(targets, opts) do
      {:ok, batch} when is_map(batch) ->
        Keyword.put(opts, :comment_batch, batch)

      {:error, reason} ->
        Logger.warning("Github comment GraphQL batch failed; falling back to conditional REST reads reason=#{inspect(reason)}")
        opts

      other ->
        Logger.warning("Github comment GraphQL batch returned unexpected value; falling back to conditional REST reads value=#{inspect(other)}")
        opts
    end
  rescue
    exception ->
      # The fallback keeps polling correct, but an exception here is a bug in
      # the batch itself, not an expected condition: log it at :error with the
      # stacktrace so it cannot hide as an indefinitely silent REST fallback.
      Logger.error(
        "Github comment GraphQL batch raised; falling back to conditional REST reads error=" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      opts
  end

  # The comments poller aggregates per-target failures as
  # [{target, {scope, taxonomy}}]; pull the first classified GitHub error
  # out so the escalation policy sees the underlying connectivity class.
  defp comments_poll_classification([{_target, {_scope, taxonomy}} | _]), do: taxonomy
  defp comments_poll_classification(reason), do: reason

  defp all_comment_targets_failed?(_targets, []), do: false

  defp all_comment_targets_failed?(targets, errors) do
    failed_targets =
      errors
      |> Enum.map(fn {target, _reason} -> target end)
      |> MapSet.new()

    targets
    |> MapSet.new()
    |> MapSet.subset?(failed_targets)
  end
end
