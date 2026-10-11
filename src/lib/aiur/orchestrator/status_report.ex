defmodule Aiur.Orchestrator.StatusReport do
  @moduledoc """
  Owns orchestrator StatusReport behavior.
  All functions execute inside the orchestrator GenServer process.
  """
  import Aiur.Orchestrator.StatusReport.RowFacts, only: [visible_polled_issues: 1]

  alias Aiur.AgentPubSub
  alias Aiur.AgentQueueStore
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.SnapshotPublisher
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusObservation
  alias Aiur.Orchestrator.StatusReport.AgentStatuses
  alias Aiur.Orchestrator.StatusReport.HumanWait
  alias Aiur.Orchestrator.StatusReport.RunningSummaries
  alias Aiur.Orchestrator.StatusReport.SnapshotPayload
  alias Aiur.RepoBase

  @doc """
  Reads the fleet view for a control query without sending a message to the
  Orchestrator.

  `status`, `agents` and `watch` read already-known state, so they must not
  queue behind a data fetch: the Orchestrator was captured holding a GitHub
  socket with thousands of messages behind it while these commands timed out
  (#1837). They are served from the `SnapshotStore` read model instead.

  Returns `{:ok, snapshot, freshness}` for both a current and a retained-but-
  aged snapshot — the caller renders the age. The freshness map is the one
  established by #1814 (`:status`, `:reason`, `:observed_at`, `:age_ms`,
  `:age_seconds`, ...), not a second vocabulary. `{:error, reason}` is reserved
  for the cases with genuinely nothing to show.

  `fleet_rows?: true` asks for the `status`/`watch` row shape under `:statuses`.
  Those rows are built on this process from the retained projection, so a query
  that does not render them (`agents`) does not pay for them.
  """
  @spec fleet_view(GenServer.server(), timeout(), keyword()) :: {:ok, map(), map()} | {:error, :timeout | :unavailable}
  def fleet_view(server \\ Aiur.Orchestrator, timeout, opts \\ []) do
    case SnapshotStore.read(server, timeout, opts) do
      {:current, snapshot, freshness} -> {:ok, snapshot, freshness}
      {:stale, snapshot, freshness} -> {:ok, snapshot, freshness}
      :snapshot_unpublished -> fleet_view_from_process(server, timeout, opts)
      :orchestrator_unavailable -> {:error, :unavailable}
    end
  end

  # Before the first publish, the read model has nothing and a bounded
  # call answers honestly. This is never steady-state, so cannot reintroduce the
  # head-of-line block: an Orchestrator that has been running long enough to be
  # busy has already published.
  #
  # One call, never two: a query that needs the rows asks for the payload and
  # the rows together, so this window costs the mailbox exactly one message.
  defp fleet_view_from_process(server, timeout, opts) do
    request = if Keyword.get(opts, :fleet_rows?, false), do: :fleet_view, else: :snapshot

    case status_api_call(server, request, timeout, true) do
      snapshot when is_map(snapshot) -> {:ok, snapshot, just_observed_freshness()}
      :timeout -> {:error, :timeout}
      _unavailable -> {:error, :unavailable}
    end
  end

  defp just_observed_freshness do
    %{
      status: :current,
      reason: nil,
      observed_at: DateTime.to_iso8601(DateTime.utc_now()),
      age_ms: 0,
      age_seconds: 0
    }
  end

  @spec snapshot_api() :: map() | :timeout | :unavailable
  def snapshot_api, do: snapshot_api(Aiur.Orchestrator, 15_000)

  @spec snapshot_api(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot_api(server, timeout), do: status_api_call(server, :snapshot, timeout, true)

  @spec status_api() :: [map()] | :timeout | :unavailable
  def status_api, do: status_api(Aiur.Orchestrator, 5_000)

  @spec status_api(GenServer.server(), timeout()) :: [map()] | :timeout | :unavailable
  def status_api(server, timeout), do: status_api_call(server, :status, timeout, true)

  @spec status_with_capacity_api(GenServer.server(), timeout()) :: {[map()], map()} | :timeout | :unavailable
  def status_with_capacity_api(server, timeout), do: status_api_call(server, :status_with_capacity, timeout, true)

  @spec poll_status_api() :: map() | :unavailable
  def poll_status_api, do: poll_status_api(Aiur.Orchestrator, 1_000)

  @spec poll_status_api(GenServer.server(), timeout()) :: map() | :unavailable
  def poll_status_api(server, timeout),
    do: status_api_call(server, :poll_status, timeout, false)

  @spec list_active_identifiers_api(GenServer.server(), timeout()) :: [String.t()]
  def list_active_identifiers_api(server, timeout) do
    if State.alive?(server) do
      try do
        GenServer.call(server, :list_active_identifiers, timeout)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @spec list_running_active_identifiers_api(GenServer.server(), timeout()) :: [String.t()]
  def list_running_active_identifiers_api(server, timeout) do
    if State.alive?(server) do
      try do
        GenServer.call(server, :list_running_active_identifiers, timeout)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @spec notify_dashboard(State.t()) :: :ok
  def notify_dashboard(state) do
    # `snapshot_ready?` means this generation has completed a poll attempt, so a
    # snapshot retained from a prior same-name orchestrator must no longer be
    # served. It does not mean the board is good: a failed candidate refresh
    # leaves `candidate_snapshot_fresh?: false`, which blanks the idle rows
    # (`visible_polled_issues/1`). Publishing that would install a blank board
    # as the last-known-good snapshot, so a later `aiur status` against a busy
    # or stopped orchestrator would render an empty fleet instead of the real
    # one — or instead of the clean "orchestrator is not running" error (#1814).
    if state.snapshot_ready? == true and state.candidate_snapshot_fresh? != false do
      :ok = publish_snapshot(state)
    end

    state
    |> running_summaries()
    |> AgentPubSub.broadcast_running_change()

    AgentPubSub.broadcast_poll_state(%{
      checking?: state.poll_check_in_progress == true,
      next_poll_due_at_ms: state.next_poll_due_at_ms,
      max_concurrent_agents: Slots.max_concurrent_agent_limit(state)
    })

    :ok
  end

  @spec publish_snapshot(State.t()) :: :ok
  def publish_snapshot(%State{} = state) do
    # The snapshot publish cadence is owned by SnapshotPublisher, a separate
    # process reading the shared write-model, so dispatch load in this mailbox
    # cannot starve the dashboard. Projection may call other stores, so it still
    # runs inside SnapshotStore rather than on the Orchestrator's dispatch
    # critical path. Project only the bounded dashboard input, not the entire
    # orchestration state.
    SnapshotPublisher.write(
      state.snapshot_key || self(),
      state.snapshot_generation,
      snapshot_input(state)
    )
  end

  @doc false
  @spec snapshot_input(State.t()) :: State.t()
  def snapshot_input(%State{} = state) do
    state
    |> Map.take([
      :orphaned_agent_reap_count,
      :startup_claim_reconciliation_complete?,
      :dispatch_capacity_sample,
      :claimed,
      :model_fallback_waiting,
      :blocked_ticket_ids,
      :agent_rate_limits,
      :agent_totals,
      :capacity_hold,
      :candidate_snapshot_fresh?,
      :dispatch_declines,
      :dispatch_hold,
      :dispatch_selection_hold,
      :dispatch_recovery,
      :effective_concurrent_agents,
      :global_pause,
      :globally_paused,
      :last_polled_issues,
      :tracker_observations,
      :last_dispatch_poll_at_ms,
      :load_envelope_state,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :effective_poll_interval_ms,
      :idle_poll_backoff,
      :poll_interval_ms,
      :retry_attempts,
      :auto_resume,
      :released_claims,
      :running,
      :session_max_concurrent_agents,
      :waiting_for_human_episodes
    ])
    |> then(&struct!(State, &1))
    |> Map.put(:ci_lifecycle, snapshot_ci_lifecycle(state))
    |> Map.put(:control_lifecycle, snapshot_control_lifecycle(state))
    |> Map.put(:queue_store, snapshot_queue_store(state))
    |> Map.put(:status_observed_at, DateTime.utc_now())
  end

  # The asynchronous projection needs only the cached result for rows it can
  # render. Keeping the rest of this lifecycle map out of the cast prevents
  # historical CI data from being copied along with every dashboard refresh.
  defp snapshot_ci_lifecycle(%State{} = state) do
    identifiers = snapshot_identifiers(state)
    poll_cache = state.ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.take(identifiers)

    %{
      approved_heads: %{},
      passed_heads: %{},
      test_failure_heads: %{},
      base_repair_invalidations: %{},
      poll_cache: poll_cache,
      rewakes: %{},
      # The dashboard never renders the parked-ready ledger, so the projection
      # carries the struct default rather than copying the live one. It still
      # has to be present: `State.t()` declares `ci_lifecycle` as a closed map,
      # and a projection missing the key is not a `State.t()`.
      parked_ready_alerts: nil
    }
  end

  # A dashboard needs bounded control history for each running issue so CLI
  # receipt correlation survives a newer request and terminal resume reasons
  # remain visible after the live event passes. The lifecycle already caps
  # this history per issue; exclude every non-rendered issue from the copy.
  defp snapshot_control_lifecycle(%State{} = state) do
    issue_ids = Enum.map(state.running, fn {_issue_id, entry} -> entry |> Map.get(:issue, %{}) |> Map.get(:id) end)
    ControlLifecycle.snapshot_for(state.control_lifecycle, issue_ids)
  end

  # Queue depth and visible operator messages are dashboard contract fields.
  # Copy only the queue entries for rows this snapshot can render so an
  # unrelated queue backlog cannot inflate the projection cast.
  defp snapshot_queue_store(%State{} = state) do
    identifiers = snapshot_identifiers(state)

    {items, pending_ids_by_target} =
      Enum.reduce(identifiers, {%{}, %{}}, fn identifier, {items, pending_ids_by_target} ->
        pending = AgentQueueStore.list_pending(state.queue_store, identifier)
        visible = AgentQueueStore.list_visible_operator_messages(state.queue_store, identifier)
        queue_items = pending ++ visible

        {
          Map.merge(items, Map.new(queue_items, &{&1.id, &1})),
          Map.put(pending_ids_by_target, identifier, Enum.map(pending, & &1.id))
        }
      end)

    %AgentQueueStore{items: items, pending_ids_by_target: pending_ids_by_target}
  end

  defp snapshot_identifiers(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.map(&Map.get(&1, :identifier))
    |> Kernel.++(Enum.map(visible_polled_issues(state), fn {_issue_id, issue} -> issue.identifier || issue.id end))
    |> Kernel.++(Enum.map(state.retry_attempts, fn {_issue_id, retry} -> Map.get(retry, :identifier) end))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @spec poll_status(State.t()) :: {:reply, map(), State.t()}
  def poll_status(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)

    {:reply,
     %{
       checking?: state.poll_check_in_progress == true,
       next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
       effective_interval_ms: state.effective_poll_interval_ms || state.poll_interval_ms,
       idle_backoff: state.idle_poll_backoff
     }, state}
  end

  @spec list_active_identifiers(State.t()) :: {:reply, [String.t()], State.t()}
  def list_active_identifiers(%State{} = state) do
    identifiers =
      state.running
      |> Map.values()
      |> Enum.map(fn entry -> entry[:identifier] || Map.get(entry, :identifier) end)
      |> Enum.reject(&is_nil/1)

    {:reply, identifiers, state}
  end

  @spec list_running_active_identifiers(State.t()) :: {:reply, [String.t()], State.t()}
  def list_running_active_identifiers(%State{} = state) do
    identifiers =
      state.running
      |> Map.values()
      |> Enum.filter(&State.active_running_entry?/1)
      |> Enum.map(fn entry -> entry[:identifier] || Map.get(entry, :identifier) end)
      |> Enum.reject(&is_nil/1)

    {:reply, identifiers, state}
  end

  @spec status(State.t()) :: {:reply, [map()], State.t()}
  def status(%State{} = state) do
    {statuses, state} = agent_statuses_and_state(state)
    {:reply, statuses, state}
  end

  @spec status_with_capacity(State.t()) :: {:reply, {[map()], map()}, State.t()}
  def status_with_capacity(%State{} = state),
    do:
      state
      |> agent_statuses_and_state()
      |> then(fn {statuses, state} ->
        {:reply, {statuses, Slots.max_concurrent_agent_status(state)}, state}
      end)

  @spec snapshot(State.t()) :: {:reply, map(), State.t()}
  # No runtime-config refresh here. The read model projects this same payload
  # from a state copy on another process and cannot refresh anything, so a
  # refresh on this path would make the two sources report different capacity
  # for the same fleet — one of them confidently wrong. The poll cycle already
  # refreshes runtime config every cycle; a read-only control query has no
  # business mutating state to do it again (#1837).
  def snapshot(%State{} = state), do: {:reply, snapshot_payload(state), state}

  @doc """
  The snapshot payload plus the `status`/`watch` rows, in one reply.

  Serves the one window the read model cannot: a generation that has not
  published yet. Answering both from a single call keeps that window at one
  mailbox message rather than two.
  """
  @spec fleet_view_call(State.t()) :: {:reply, map(), State.t()}
  def fleet_view_call(%State{} = state),
    do: {:reply, StatusObservation.refresh(Map.put(snapshot_payload(state), :statuses, agent_statuses(state))), state}

  @doc false
  @spec snapshot_payload(State.t()) :: map()
  defdelegate snapshot_payload(state), to: SnapshotPayload

  @spec running_summaries(State.t()) :: [map()]
  defdelegate running_summaries(state), to: RunningSummaries

  @spec agent_statuses(State.t()) :: [map()]
  defdelegate agent_statuses(state), to: AgentStatuses

  @doc false
  @spec agent_statuses(State.t(), (timeout() -> term())) :: [map()]
  defdelegate agent_statuses(state, status_fun), to: AgentStatuses

  @doc false
  @spec sync_waiting_for_human_episodes(State.t(), DateTime.t()) :: State.t()
  defdelegate sync_waiting_for_human_episodes(state, now), to: HumanWait

  @doc false
  @spec waiting_for_human_alert_due?(DateTime.t(), DateTime.t()) :: boolean()
  defdelegate waiting_for_human_alert_due?(since, now), to: HumanWait

  @doc false
  @spec prewarm_phase((timeout() -> term())) :: atom() | :unavailable
  defdelegate prewarm_phase(status_fun \\ &RepoBase.status/1), to: AgentStatuses

  @spec next_poll_in_ms(integer() | nil, integer()) :: non_neg_integer() | nil
  defdelegate next_poll_in_ms(next_poll_due_at_ms, now_ms), to: SnapshotPayload

  defp agent_statuses_and_state(%State{} = state), do: {agent_statuses(state), state}

  defp status_api_call(server, request, timeout, distinguish_timeout?) do
    if State.alive?(server) do
      try do
        GenServer.call(server, request, timeout)
      catch
        :exit, {:timeout, _} when distinguish_timeout? -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end
end
