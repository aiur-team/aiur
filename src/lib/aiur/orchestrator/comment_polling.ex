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

  alias Aiur.{Alerts, Config}
  alias Aiur.Events.{GithubCommentsPoller, GithubFirehose}
  alias Aiur.GitHub.CommentPollBatch
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling.TargetSelection
  alias Aiur.Orchestrator.State

  @recent_merge_persistence_retry_limit 3

  # Long enough that a slow but working poll is never restarted underneath
  # itself (`GithubCommentsPoller` allows 60s per target), short enough that a
  # worker lost without a reply costs one skipped cycle, not every future one.
  @comment_poll_abandon_after_ms 180_000

  @spec poll_github_firehose(State.t(), keyword()) :: State.t()
  def poll_github_firehose(%State{} = state, opts \\ []) do
    poll_opts =
      opts
      |> Keyword.put_new(:etag, state.events_etag)
      |> Keyword.put_new(:last_event_id, state.events_last_id)

    case GithubFirehose.poll(poll_opts) do
      {:ok, %{etag: etag, last_event_id: last_event_id, count: count} = result} ->
        if count > 0, do: Logger.debug("aiur_perf github_firehose published count=#{count}")

        state =
          state
          |> Orchestrator.note_github_connectivity_success(:firehose)
          |> Orchestrator.note_github_poll_interval(:firehose, Map.get(result, :poll_interval))
          |> note_recent_merge_persistence_success(Map.get(result, :recent_merge_persistence))

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
      true -> spawn_comment_poll(state, opts, now_ms)
    end
  end

  defp tracker_kind(opts), do: Keyword.get_lazy(opts, :tracker_kind, &Config.tracker_kind/0)

  @doc """
  Folds a completed asynchronous comment poll into the current state.

  Results from an abandoned or superseded poll are dropped: the reference names
  the poll this state is waiting for, and anything else is a straggler whose
  cursors would move the fleet backwards.
  """
  @spec apply_async(State.t(), reference(), term()) :: State.t()
  def apply_async(%State{github_comment_poll: %{ref: ref} = poll} = state, ref, payload) do
    demonitor_comment_poll(poll)
    state = %{state | github_comment_poll: nil}
    apply_comment_poll(state, payload)
  end

  def apply_async(%State{} = state, _stale_ref, _payload), do: state

  @doc false
  @spec apply_async_down(State.t(), reference()) :: {:handled, State.t()} | :unhandled
  def apply_async_down(%State{github_comment_poll: %{monitor_ref: monitor_ref}} = state, monitor_ref),
    do: {:handled, %{state | github_comment_poll: nil}}

  def apply_async_down(%State{}, _stale_monitor_ref), do: :unhandled

  defp comment_poll_in_flight?(%State{github_comment_poll: %{started_at_ms: started_at_ms}} = state, now_ms)
       when is_integer(started_at_ms) do
    if now_ms - started_at_ms < @comment_poll_abandon_after_ms do
      true
    else
      Logger.warning(
        "GithubCommentsPoller poll has not answered in #{@comment_poll_abandon_after_ms}ms; " <>
          "abandoning it and starting a fresh one"
      )

      terminate_poll(state.github_comment_poll)
      false
    end
  end

  defp comment_poll_in_flight?(_state, _now_ms), do: false

  defp spawn_comment_poll(%State{} = state, opts, now_ms) do
    orchestrator = self()
    ref = make_ref()

    task_fun = fn -> send(orchestrator, {:github_comments_polled, ref, run_comment_poll(state, opts)}) end
    {pid, owner} = spawn_owned_poll(orchestrator, state.snapshot_key, task_fun)
    monitor_ref = Process.monitor(pid)

    poll = %{ref: ref, pid: pid, owner: owner, monitor_ref: monitor_ref, started_at_ms: now_ms}
    %{state | github_comment_poll: poll}
  end

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
          reap_poll_tree(pid, monitor_ref)
        else
          Process.demonitor(monitor_ref, [:flush])
        end
    end

    :ok
  end

  def terminate_poll(_poll), do: :ok

  # The poll temporarily traps exits while Task.async_stream owns its target
  # tasks, so a link is not an inverse lifetime edge. This independent monitor
  # turns owner death into an untrappable kill and waits for the poll to stop.
  defp spawn_owned_poll(orchestrator, ownership_key, task_fun) do
    started_ref = make_ref()

    {guardian, guardian_ref} =
      spawn_monitor(fn ->
        orchestrator_ref = Process.monitor(orchestrator)

        case claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref) do
          :ok ->
            {poll, poll_ref} = spawn_monitor(task_fun)
            send(orchestrator, {started_ref, poll})
            guard_poll_lifetime(orchestrator, orchestrator_ref, poll, poll_ref)

          :orchestrator_down ->
            :ok
        end
      end)

    receive do
      {^started_ref, poll} ->
        Process.demonitor(guardian_ref, [:flush])
        {poll, guardian}

      {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
        exit({:comment_poll_owner_start_failed, reason})
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
        end
    end
  end

  defp guard_poll_lifetime(orchestrator, orchestrator_ref, poll, poll_ref) do
    receive do
      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        reap_poll_tree(poll, poll_ref)

      {:stop_owned_poll, caller, stop_ref} ->
        reap_poll_tree(poll, poll_ref)
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^poll_ref, :process, ^poll, _reason} ->
        Process.demonitor(orchestrator_ref, [:flush])
    end
  end

  defp reap_poll_tree(poll, poll_ref) do
    descendants = linked_descendants(poll, MapSet.new([self()]))
    descendant_refs = Enum.map(descendants, &{&1, Process.monitor(&1)})
    Process.exit(poll, :kill)
    await_process_down(poll, poll_ref)
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

  defp demonitor_comment_poll(%{monitor_ref: monitor_ref}) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
  end

  defp demonitor_comment_poll(_poll), do: :ok

  # The I/O half. Runs on whichever process the caller chose — never touches the
  # state it was handed, so its result can be folded into a newer one.
  defp run_comment_poll(%State{} = state, opts) do
    case TargetSelection.github_comment_poll_targets_with_cache(state, opts) do
      {:ok, targets, human_review_targets, watch_targets, cache} ->
        {:ok, cache, human_review_targets, poll_targets(state, targets, human_review_targets, watch_targets, opts)}

      {:error, reason} ->
        {:error, reason}
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

  defp poll_targets(%State{}, [], _human_review_targets, _watch_targets, _opts), do: :no_targets

  defp poll_targets(%State{} = state, targets, human_review_targets, watch_targets, opts) when is_list(targets) do
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

    poll_opts = put_comment_batch(poll_opts, targets)

    {targets, GithubCommentsPoller.poll(targets, poll_opts)}
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
