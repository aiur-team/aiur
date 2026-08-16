defmodule Aiur.Orchestrator.StatusReport do
  @moduledoc """
  Owns orchestrator StatusReport behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.AgentEvents
  alias Aiur.AgentPubSub
  alias Aiur.AgentQueueStore
  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.CodingAgent
  alias Aiur.Config
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.AutoResume
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.SnapshotPublisher
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReason
  alias Aiur.Orchestrator.WaitingReason
  alias Aiur.RepoBase
  alias Aiur.TicketActivity
  alias Aiur.TrackerIdentity

  # `TicketActivity.snapshots/1` is a call into an in-memory projection on this
  # node, so the work itself is microseconds; the only thing this budget has to
  # cover is queueing. 100 ms did not: behind a burst of ticket events, or any
  # ordinary VM pause, the call timed out and the whole fleet's progress
  # collapsed to a single failure value at once.
  #
  # 500 ms is bounded from both sides. Below, it is five times the budget that
  # was observed to fail, which puts it far outside normal mailbox queueing for
  # a projection this small. Above, this call blocks the Orchestrator process
  # while it runs and snapshots are rebuilt on every state change, so it must
  # stay comfortably inside the smallest caller budget in the tree (1 s, e.g.
  # `Orchestrator.snapshot/2`) and leave room for the rest of the payload. Half
  # of that is the largest value that still does.
  @activity_snapshot_timeout_ms 500
  @repo_base_status_timeout_ms 100
  @waiting_for_human_alert_after_seconds 600

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

  # Only reachable before the first publish of a generation — the short window
  # after a restart, where the read model genuinely has nothing and a bounded
  # call is the honest way to get an answer rather than telling the operator to
  # retry. It is never the steady-state path, so it cannot reintroduce the
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
    if state.snapshot_ready? == true, do: :ok = publish_snapshot(state)

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
      :agent_rate_limits,
      :agent_totals,
      :capacity_hold,
      :dispatch_hold,
      # `agent_statuses/1` reads the codex thrash budget to explain why an idle
      # ticket is not dispatching. Projecting without it would fall back to the
      # struct default and render a confident wrong *reason* on every idle row.
      :dispatch_recovery,
      :effective_concurrent_agents,
      :global_pause,
      :globally_paused,
      :last_polled_issues,
      :load_envelope_state,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :poll_interval_ms,
      :retry_attempts,
      :auto_resume,
      :released_claims,
      :running,
      :session_max_concurrent_agents
    ])
    |> then(&struct!(State, &1))
    |> Map.put(:ci_lifecycle, snapshot_ci_lifecycle(state))
    |> Map.put(:control_lifecycle, snapshot_control_lifecycle(state))
    |> Map.put(:queue_store, snapshot_queue_store(state))
  end

  # The asynchronous projection needs only the cached result for rows it can
  # render. Keeping the rest of this lifecycle map out of the cast prevents
  # historical CI data from being copied along with every dashboard refresh.
  defp snapshot_ci_lifecycle(%State{} = state) do
    identifiers = snapshot_identifiers(state)
    poll_cache = state.ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.take(identifiers)

    %{
      approved_heads: %{},
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
    |> Kernel.++(Enum.map(state.last_polled_issues, fn {_issue_id, issue} -> issue.identifier || issue.id end))
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
       next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms)
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
    do: {:reply, Map.put(snapshot_payload(state), :statuses, agent_statuses(state)), state}

  @doc false
  @spec snapshot_payload(State.t()) :: map()
  def snapshot_payload(%State{} = state) do
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    stall_timeout_seconds = stall_timeout_seconds()
    activity_by_identity = activity_by_identity()

    running =
      Enum.map(
        state.running,
        &running_snapshot(state, &1, now, stall_timeout_seconds, activity_by_identity)
      )

    retrying =
      Enum.map(state.retry_attempts, &retry_snapshot(state, &1, now_ms, activity_by_identity))

    idle = idle_snapshot(state, now_ms, activity_by_identity)

    %{
      running: running,
      retrying: retrying,
      idle: idle,
      # The `status`/`watch` rows are deliberately *not* built here. This runs on
      # every state change, and `agent_statuses/1` reads `dispatch-budgets.json`
      # and calls `RepoBase`; paying that continuously to save it on a command an
      # operator types occasionally is a bad trade on a box that also runs the
      # fleet. `SnapshotStore.read/3` builds them from the retained projection,
      # on the reader's process, when someone asks (#1837).
      agent_totals: state.agent_totals,
      capacity: Slots.max_concurrent_agent_status(state),
      capacity_hold: capacity_hold_payload(state, now_ms),
      dispatch_hold: dispatch_hold_payload(state, now_ms),
      globally_paused: state.globally_paused == true,
      global_pause: %{
        globally_paused: state.globally_paused == true,
        paused_at: Map.get(state.global_pause, :paused_at),
        source: Map.get(state.global_pause, :source)
      },
      rate_limits: Map.get(state, :agent_rate_limits),
      polling: %{
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms
      }
    }
  end

  defp capacity_hold_active?(%State{} = state) do
    match?(%{signal: _signal}, state.capacity_hold)
  end

  defp capacity_hold_payload(%State{} = state, now_ms) do
    case state.capacity_hold do
      %{signal: signal, measured: measured, threshold: threshold, held_since_ms: held_since_ms} ->
        %{
          held?: true,
          signal: signal,
          measured: measured,
          threshold: threshold,
          held_for_seconds: max(div(now_ms - held_since_ms, 1_000), 0)
        }

      _other ->
        %{held?: false, signal: nil, measured: nil, threshold: nil, held_for_seconds: 0}
    end
  end

  defp dispatch_hold_payload(%State{} = state, now_ms) do
    case state.dispatch_hold do
      %{reason: reason, detail: detail, held_since_ms: held_since_ms} ->
        %{
          held?: true,
          reason: reason,
          detail: detail,
          held_for_seconds: max(div(now_ms - held_since_ms, 1_000), 0)
        }

      _other ->
        %{held?: false, reason: nil, detail: nil, held_for_seconds: 0}
    end
  end

  defp running_snapshot(
         %State{} = state,
         {issue_id, metadata},
         now,
         stall_timeout_seconds,
         activity_by_identity
       ) do
    capabilities = OM.issue_control_capabilities(state, metadata.identifier, metadata)
    work_state = get_in(metadata, [:control, :status]) || :working
    pause_reason = Map.get(metadata, :paused_reason)
    started_at = Map.get(metadata, :started_at)
    stale_for_seconds = stale_for_seconds(metadata, now)
    {open_decision_count, open_decision_count_health} = open_decision_count(metadata.identifier)

    waiting_reason =
      WaitingReason.for_running(%{
        tracker_state: metadata.issue.state,
        pause_reason: pause_reason,
        work_state: work_state,
        open_decision_count: open_decision_count,
        stale_for_seconds: stale_for_seconds,
        stall_timeout_seconds: stall_timeout_seconds
      })

    %{
      issue_id: issue_id,
      identifier: metadata.identifier,
      tracker_identity: Issue.tracker_identity(metadata.issue),
      state: metadata.issue.state,
      tag: State.issue_tag(metadata.issue),
      title: Map.get(metadata.issue, :title),
      url: Map.get(metadata.issue, :url),
      worker_host: Map.get(metadata, :worker_host),
      workspace_path: Map.get(metadata, :workspace_path),
      session_id: Map.get(metadata, :session_id),
      live_conversation: Map.get(metadata, :live_conversation),
      codex_app_server_pid: Map.get(metadata, :codex_app_server_pid),
      agent_input_tokens: Map.get(metadata, :agent_input_tokens, 0),
      agent_output_tokens: Map.get(metadata, :agent_output_tokens, 0),
      agent_total_tokens: Map.get(metadata, :agent_total_tokens, 0),
      turn_count: Map.get(metadata, :turn_count, 0),
      started_at: started_at,
      last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
      last_codex_message: Map.get(metadata, :last_codex_message),
      last_codex_event: Map.get(metadata, :last_codex_event),
      work_state: work_state,
      pause_reason: pause_reason,
      tracker_paused: Issue.paused?(metadata.issue),
      queue_depth: capabilities.queue_depth,
      pending_operator_messages: OM.pending_operator_messages_for_issue(state, metadata.identifier),
      control: capabilities,
      runtime_seconds: State.running_seconds(started_at, now),
      stale_for_seconds: stale_for_seconds,
      waiting_reason: waiting_reason,
      blocked_by: known_blocked_by(metadata.issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(metadata.issue, :priority),
      activity_stage: activity_stage(Issue.tracker_identity(metadata.issue), activity_by_identity),
      ci_result: cached_ci_result(state, metadata.identifier)
    }
    |> Map.merge(progress_facts(Issue.tracker_identity(metadata.issue), activity_by_identity))
    |> Map.merge(running_execution_facts(metadata))
  end

  defp retry_snapshot(
         %State{} = state,
         {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry},
         now_ms,
         activity_by_identity
       ) do
    identifier = Map.get(retry, :identifier)
    issue = Map.get(state.last_polled_issues, issue_id)
    tracker_identity = retry_snapshot_tracker_identity(retry, issue)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)

    %{
      issue_id: issue_id,
      attempt: attempt,
      due_in_ms: max(0, due_at_ms - now_ms),
      identifier: identifier,
      tracker_identity: tracker_identity,
      state: issue && issue.state,
      tag: issue && State.issue_tag(issue),
      title: issue && issue.title,
      url: issue && issue.url,
      error: Map.get(retry, :error),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      waiting_reason: WaitingReason.for_retry(),
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(issue || %{}, :priority) || Map.get(retry, :priority),
      activity_stage: activity_stage(tracker_identity, activity_by_identity),
      ci_result: cached_ci_result(state, identifier)
    }
    |> Map.merge(progress_facts(tracker_identity, activity_by_identity))
    |> Map.merge(issue_execution_facts(issue))
  end

  defp idle_snapshot(%State{} = state, now_ms, activity_by_identity) do
    running_issue_ids = MapSet.new(Map.keys(state.running))

    # Also exclude issues already shown in the retry-backoff bucket — they're
    # tracker-active (still in `last_polled_issues`) but not in `running`,
    # so without this they'd double up as a contradictory second row here.
    retrying_issue_ids = MapSet.new(Map.keys(state.retry_attempts))

    excluded_issue_ids = MapSet.union(running_issue_ids, retrying_issue_ids)
    terminal_states = DispatchPolicy.terminal_state_set()

    idle_issues =
      state.last_polled_issues
      |> Enum.reject(fn {issue_id, _issue} -> MapSet.member?(excluded_issue_ids, issue_id) end)

    # One durable-store read for the whole board, not one per idle ticket.
    latch_statuses =
      Dispatcher.dispatch_latch_statuses(state, Enum.map(idle_issues, fn {id, _} -> id end))

    Enum.map(idle_issues, fn {_issue_id, issue} ->
      idle_issue_snapshot(
        state,
        issue,
        terminal_states,
        now_ms,
        latch_statuses,
        activity_by_identity
      )
    end)
  end

  defp idle_issue_snapshot(
         %State{} = state,
         %Issue{} = issue,
         _terminal_states,
         now_ms,
         latch_statuses,
         activity_by_identity
       ) do
    identifier = issue.identifier || issue.id
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)
    latch = Map.get(latch_statuses, issue.id, :none)
    release = Map.get(state.released_claims, issue.id)
    idle_evidence = idle_evidence(state, issue, latch, open_decision_count, now_ms)

    %{
      issue_id: issue.id,
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: issue.state,
      work_state: idle_issue_work_state(issue),
      tag: State.issue_tag(issue),
      title: issue.title,
      url: issue.url,
      tracker_paused: Issue.paused?(issue),
      queue_depth: OM.queue_depth_for_issue(state, identifier),
      # #1453 supplies the idle-reason evidence; #1457 renders it.
      dispatch_latch: idle_evidence.dispatch_latch,
      auto_resume_retry_in_ms: idle_evidence.auto_resume_retry_in_ms,
      dispatch_hold_reason: idle_evidence.dispatch_hold_reason,
      capacity_hold_active?: idle_evidence.capacity_hold_active?,
      waiting_reason: idle_evidence_waiting_reason(idle_evidence, release),
      claim_released?: not is_nil(release),
      claim_release_cause: release && release.cause,
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(issue, :priority),
      activity_stage: activity_stage(Issue.tracker_identity(issue), activity_by_identity),
      ci_result: cached_ci_result(state, identifier)
    }
    |> Map.merge(progress_facts(Issue.tracker_identity(issue), activity_by_identity))
    |> Map.merge(issue_execution_facts(issue))
  end

  # A released claim is the one idle signal that must win over every other
  # reason: ownership evaporated and the operator (or the automatic re-claim)
  # has to act. Prefer the claim-release classifier so the row never reads as a
  # plain awaiting-dispatch; the detailed cause and retry window stay in
  # `reason` (`StatusReason.render`) and `claim_release_cause`.
  defp idle_evidence_waiting_reason(_evidence, %{cause: cause}) when not is_nil(cause), do: :claim_released

  defp idle_evidence_waiting_reason(%{waiting_reason: fallback}, _release), do: fallback

  defp issue_execution_facts(%Issue{} = issue) do
    backend = CodingAgent.backend_for(issue)

    %{
      backend: backend,
      agent_family: CodingAgent.family_for(backend),
      requested_model: CodingAgent.model_for(issue),
      effort: CodingAgent.effort_for(issue)
    }
    |> Map.merge(issue_classification_facts(issue))
  end

  defp issue_execution_facts(_issue), do: %{}

  defp running_execution_facts(entry) do
    execution = session_execution(entry)
    backend = Map.get(execution, :backend)

    %{
      backend: backend,
      agent_family: CodingAgent.family_for(backend),
      requested_model: Map.get(execution, :requested_model),
      effort: Map.get(execution, :effort)
    }
    |> Map.merge(issue_classification_facts(Map.get(entry, :issue)))
  end

  defp issue_classification_facts(%Issue{} = issue) do
    %{
      complexity: issue_complexity(issue),
      labels: Issue.label_names(issue)
    }
  end

  defp issue_classification_facts(_issue), do: %{}

  defp session_execution(entry) when is_map(entry) do
    case Map.get(entry, :session_execution) do
      execution when is_map(execution) -> execution
      _execution -> %{}
    end
  end

  defp cached_ci_result(%State{} = state, identifier) do
    state.ci_lifecycle
    |> Map.get(:poll_cache, %{})
    |> Map.get(identifier)
  end

  defp stale_for_seconds(metadata, %DateTime{} = now) do
    case Map.get(metadata, :last_codex_timestamp) || Map.get(metadata, :started_at) do
      %DateTime{} = last_activity -> max(0, DateTime.diff(now, last_activity, :second))
      _ -> nil
    end
  end

  defp stall_timeout_seconds do
    case Config.agent_stall_timeout_ms() do
      0 -> 0
      timeout_ms -> div(timeout_ms + 999, 1_000)
    end
  end

  defp open_decision_count(identifier) when is_binary(identifier) do
    case SubscriptionStore.open_attention_count_result(identifier) do
      {:ok, count} -> {count, :available}
      {:error, :unavailable} -> {0, :unavailable}
    end
  end

  defp open_decision_count(_identifier), do: {0, :unavailable}

  # An unreachable, unstarted or too-slow TicketActivity yields an empty join,
  # which `progress_facts/2` reads as `:unknown` for every identity it looks
  # up. That distinction is the whole point: the failure path must say "we
  # could not measure", never "every agent is at 0%", which is what the fleet
  # used to report in unison on any transient hiccup here.
  defp activity_by_identity do
    with pid when is_pid(pid) <- Process.whereis(TicketActivity),
         %{entries: entries} when is_list(entries) <-
           TicketActivity.snapshots(timeout: @activity_snapshot_timeout_ms) do
      Enum.reduce(entries, %{}, &put_activity_entry/2)
    else
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp put_activity_entry(entry, acc) do
    case TrackerIdentity.github_key(Map.get(entry, :identity)) do
      nil -> acc
      identity_key -> Map.put(acc, identity_key, entry)
    end
  end

  # Progress has three honest states, and every consumer gets all three:
  #
  #   :fresh   - observed inside the TicketActivity staleness window.
  #   :stale   - a real reading exists but is older than the window. The
  #              percent is RETAINED. `Projection.progress_snapshot/3` keeps
  #              the measured value on purpose and only annotates its age; the
  #              honest reading of an aged 70% is "70%, a while ago", never 0%.
  #   :unknown - nothing was ever observed for this ticket, or TicketActivity
  #              could not be consulted at all. The percent is `nil`.
  #
  # This used to substitute integer `0` for both of the latter two, which made
  # the Stream Deck flicker 0 -> 70 -> 0 on a ticket that was progressing
  # perfectly well: agents do not re-emit progress every minute, so a good
  # reading went stale about a minute after it landed and was replaced by a
  # measurement nobody took.
  defp progress_facts(identity, activity_by_identity) do
    case get_in(activity_by_identity, [TrackerIdentity.github_key(identity), :progress]) do
      %{status: :known, freshness: freshness, percent: percent}
      when freshness in [:fresh, :stale] ->
        known_progress_facts(freshness, normalized_percent(percent))

      _ ->
        %{progress_percent: nil, progress_freshness: :unknown}
    end
  end

  defp known_progress_facts(_freshness, nil), do: %{progress_percent: nil, progress_freshness: :unknown}

  defp known_progress_facts(freshness, percent), do: %{progress_percent: percent, progress_freshness: freshness}

  # Agents emit whole percentages today, but a float is a real measurement and
  # rounding keeps it. The previous `is_integer/1` guard silently turned 70.5
  # into 0 — the one thing a percent must never be turned into.
  defp normalized_percent(percent) when is_integer(percent) and percent in 0..100, do: percent
  defp normalized_percent(percent) when is_float(percent), do: percent |> round() |> normalized_percent()
  defp normalized_percent(_percent), do: nil

  # Sibling of `progress_facts/2` over the same joined TicketActivity entry:
  # the agent's workflow stage (brainstorm/plan/work/review).
  #
  # Deliberately NOT annotated with freshness, where progress is. The two look
  # alike and are not. Progress is a measurement that decays: an hour-old 40%
  # may no longer be true, so its age travels with it. A stage is a *state* with
  # explicit transitions — it changes only when the agent emits
  # `phase.<stage>.start|end`, and `observed_at` records that transition, not a
  # confirmation that the state still holds. Requiring it to be recent asks the
  # agent to keep re-announcing a phase it never left: with the default
  # 60-second staleness window, a twenty-minute work phase would report its
  # stage for the first minute and nothing for the other nineteen. The reducer
  # already writes `value: nil` on a phase end, so a finished phase clears
  # itself rather than lingering.
  defp activity_stage(identity, activity_by_identity) do
    case get_in(activity_by_identity, [TrackerIdentity.github_key(identity), :stage]) do
      %{status: :known, value: stage} when is_atom(stage) and not is_nil(stage) -> stage
      _ -> nil
    end
  end

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

  @spec running_summaries(State.t()) :: [map()]
  def running_summaries(state) do
    now = DateTime.utc_now()

    polled_summaries =
      state.last_polled_issues
      |> Enum.map(&polled_summary(&1, state, now))

    # Cover the narrow race where an agent is mid-dispatch and the
    # tracker poll hasn't refreshed yet — those issues live in
    # `state.running` but not in `last_polled_issues`.
    extra_running =
      state.running
      |> Enum.flat_map(&unpolled_running_summary(&1, state.last_polled_issues, now))

    (polled_summaries ++ extra_running)
    |> Enum.reject(fn %{identifier: id} -> id == "" end)
  end

  defp polled_summary({issue_id, issue}, state, now) do
    identifier = Map.get(issue, :identifier) || ""
    tag = State.issue_tag(issue)
    title = Map.get(issue, :title)

    case Map.get(state.running, issue_id) do
      nil -> queued_summary(identifier, issue, tag, title)
      entry -> running_summary(identifier, entry, tag, title, now)
    end
  end

  defp queued_summary(identifier, issue, tag, title) do
    # Has an `agent:*` label but no Aiur slot is running it.
    AgentEvents.agent_summary(identifier, :queued, 0, %{
      tag: tag,
      title: title,
      tracker_identity: Issue.tracker_identity(issue),
      work_state: idle_issue_work_state(issue),
      pause_reason: idle_issue_pause_reason(issue)
    })
  end

  defp unpolled_running_summary({issue_id, entry}, polled_issues, now) do
    if Map.has_key?(polled_issues, issue_id) do
      []
    else
      [running_summary(Map.get(entry, :identifier) || "", entry, now)]
    end
  end

  defp running_summary(identifier, entry, now) do
    issue = Map.get(entry, :issue) || %{}

    running_summary(
      identifier,
      entry,
      State.issue_tag(issue),
      get_in(entry, [:issue, Access.key(:title)]),
      now
    )
  end

  defp running_summary(identifier, entry, tag, title, now) do
    AgentEvents.agent_summary(identifier, :running, 0, %{
      tag: tag,
      title: title,
      tracker_identity: Issue.tracker_identity(Map.get(entry, :issue)),
      runtime_seconds: State.effective_runtime_seconds(entry, now),
      turn_count: Map.get(entry, :turn_count, 0),
      work_state: get_in(entry, [:control, :status]) || :working,
      pause_reason: Map.get(entry, :paused_reason),
      backend: entry_backend(entry),
      model: entry_model(entry),
      remote_control: RC.remote_control_summary(entry)
    })
  end

  # Session-resolved backend for a running entry, so the agent list names the
  # engine that actually started rather than re-routing from mutable config.
  # nil while the dispatched worker is still warming up.
  defp entry_backend(entry) do
    entry |> session_execution() |> Map.get(:backend)
  end

  # Session-requested model variant for a running entry (for example
  # "opus-4-8" or "gpt-5.5"). nil while warming up or when the backend default
  # is authoritative; agent_summary drops nil and the renderer shows the base.
  defp entry_model(entry) do
    entry |> session_execution() |> Map.get(:requested_model)
  end

  # Highest `complexity:N` label on the issue (nil when unlabelled). Reused by
  # the status rows so `aiur watch` can render the cx column without a tracker
  # round-trip — the issue is already in memory.
  defp issue_complexity(%Issue{} = issue), do: CodingAgent.complexity_level(issue)
  defp issue_complexity(_issue), do: nil

  @spec agent_statuses(State.t()) :: [map()]
  def agent_statuses(%State{} = state) do
    status_fun =
      if Config.prewarm_enabled?(),
        do: &RepoBase.status/1,
        else: fn _timeout -> {:unavailable, nil} end

    agent_statuses(state, status_fun)
  end

  defp agent_statuses_and_state(%State{} = state) do
    status_fun =
      if Config.prewarm_enabled?(),
        do: &RepoBase.status/1,
        else: fn _timeout -> {:unavailable, nil} end

    {statuses, state} = agent_statuses_raw(state, status_fun)
    {statuses, state}
  end

  @doc false
  @spec sync_waiting_for_human_episodes(State.t(), DateTime.t()) :: State.t()
  def sync_waiting_for_human_episodes(%State{} = state, %DateTime{} = now) do
    track_waiting_for_human_episodes(state, agent_statuses(state), now)
  end

  @doc false
  @spec agent_statuses(State.t(), (timeout() -> term())) :: [map()]
  def agent_statuses(%State{} = state, status_fun) when is_function(status_fun, 1) do
    {statuses, _state} = agent_statuses_raw(state, status_fun)
    statuses
  end

  defp agent_statuses_raw(%State{} = state, status_fun) when is_function(status_fun, 1) do
    now = DateTime.utc_now()
    prewarm_phase = prewarm_phase(status_fun)

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    statuses =
      (running_statuses(state, now) ++
         retry_statuses(state) ++ idle_statuses(state, running_by_identifier, prewarm_phase))
      |> Enum.sort_by(fn status -> to_string(status.identifier || status.issue_id || "") end)

    {statuses, state}
  end

  defp running_statuses(%State{} = state, %DateTime{} = now) do
    Enum.map(state.running, fn {issue_id, entry} ->
      running_status(state, issue_id, entry, now)
    end)
  end

  defp running_status(%State{} = state, issue_id, entry, now) do
    identifier = Map.get(entry, :identifier) || issue_id
    issue = Map.get(entry, :issue) || %{}
    work_state = get_in(entry, [:control, :status]) || :working
    capabilities = OM.issue_control_capabilities(state, identifier, entry)
    pause_reason = Map.get(entry, :paused_reason)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)
    stale_for_seconds = stale_for_seconds(entry, now)

    waiting_reason =
      WaitingReason.for_running(%{
        tracker_state: Map.get(issue, :state),
        pause_reason: pause_reason,
        work_state: work_state,
        open_decision_count: open_decision_count,
        stale_for_seconds: stale_for_seconds,
        stall_timeout_seconds: stall_timeout_seconds()
      })

    %{
      issue_id: issue_id,
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: if(work_state == :paused, do: :paused, else: :running),
      work_state: work_state,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: State.issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      live_conversation: Map.get(entry, :live_conversation),
      runtime_seconds: State.running_seconds(Map.get(entry, :started_at), now),
      queue_depth: capabilities.queue_depth,
      control: capabilities,
      complexity: issue_complexity(issue),
      last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
      last_codex_message: Map.get(entry, :last_codex_message),
      last_codex_event: Map.get(entry, :last_codex_event),
      reason: if(work_state == :paused, do: StatusReason.for_pause(pause_reason)),
      waiting_reason: waiting_reason,
      pause_reason: pause_reason,
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health
    }
  end

  defp retry_statuses(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.map(state.retry_attempts, fn {issue_id, retry} ->
      issue = Map.get(state.last_polled_issues, issue_id)
      identifier = Map.get(retry, :identifier) || Map.get(issue || %{}, :identifier) || issue_id
      due_in_ms = max(0, Map.get(retry, :due_at_ms, now_ms) - now_ms)
      retry_reason = StatusReason.for_retry(Map.get(retry, :error), due_in_ms)
      tracker_paused = tracker_paused?(issue)

      %{
        issue_id: issue_id,
        identifier: identifier,
        tracker_identity: retry_snapshot_tracker_identity(retry, issue),
        state: :paused,
        work_state: :paused,
        tracker_state: Map.get(issue || %{}, :state),
        tracker_paused: tracker_paused,
        tag: State.issue_tag(issue),
        title: Map.get(issue || %{}, :title),
        url: Map.get(issue || %{}, :url),
        worker_host: Map.get(retry, :worker_host),
        workspace_path: Map.get(retry, :workspace_path),
        session_id: nil,
        live_conversation: nil,
        runtime_seconds: 0,
        queue_depth: idle_queue_depth(state, identifier),
        complexity: issue_complexity(issue),
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil,
        retry_attempt: Map.get(retry, :attempt),
        retry_reason: retry_reason,
        waiting_reason: WaitingReason.for_retry(),
        pause_reason: if(tracker_paused, do: tracker_pause_cause(state)),
        blocked_by: known_blocked_by(issue),
        reason:
          if tracker_paused do
            StatusReason.for_paused_retry(
              tracker_pause_cause(state),
              Map.get(retry, :error),
              due_in_ms
            )
          else
            retry_reason
          end
      }
    end)
  end

  defp tracker_paused?(%Issue{} = issue), do: Issue.paused?(issue)
  defp tracker_paused?(issue) when is_map(issue), do: Map.get(issue, :paused) == true
  defp tracker_paused?(_issue), do: false

  # `Config.agent_max_dispatches_per_ticket/0` is a `WorkflowStore` GenServer
  # call that re-stats and re-reads the config file, so resolving it per idle
  # row turned one status render into one round-trip per backlog ticket, all
  # serialized inside this handle_call. That is why `status` and `agents` were
  # slow (and `alerts`, which never touches the orchestrator, was not) — #1684.
  # Read it once per snapshot.
  defp idle_statuses(%State{} = state, _running_by_identifier, prewarm_phase) do
    max_dispatches = Config.agent_max_dispatches_per_ticket()

    idle_issues =
      Enum.reject(state.last_polled_issues, fn {issue_id, _issue} ->
        Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id)
      end)

    latch_statuses =
      Dispatcher.dispatch_latch_statuses(
        state,
        Enum.map(idle_issues, fn {issue_id, _issue} -> issue_id end)
      )

    Enum.map(idle_issues, fn {issue_id, issue} ->
      idle_status(
        state,
        issue,
        prewarm_phase,
        max_dispatches,
        Map.get(latch_statuses, issue_id, :none)
      )
    end)
  end

  defp idle_status(%State{} = state, issue, prewarm_phase, max_dispatches, latch_status) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, :id)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget, Map.get(issue, :id)]) || %{}
    prewarm_blocked? = prewarm_blocked?(prewarm_phase)

    work_state = idle_issue_work_state(issue)
    pause_reason = idle_issue_pause_reason(issue)
    release = Map.get(state.released_claims, Map.get(issue, :id))

    idle_evidence = idle_evidence(state, issue, latch_status, open_decision_count, System.monotonic_time(:millisecond))
    waiting_reason = idle_evidence_waiting_reason(idle_evidence, release)

    %{
      issue_id: Map.get(issue, :id),
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: if(work_state == :paused, do: :paused, else: :idle),
      work_state: work_state,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: State.issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      runtime_seconds: 0,
      queue_depth: idle_queue_depth(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil,
      claim_released?: not is_nil(release),
      claim_release_cause: release && release.cause,
      reason:
        idle_status_reason(
          work_state,
          pause_reason,
          prewarm_blocked?,
          budget,
          max_dispatches,
          latch_status,
          release && release.cause,
          idle_evidence.auto_resume_retry_in_ms
        ),
      waiting_reason: waiting_reason,
      dispatch_latch: idle_evidence.dispatch_latch,
      auto_resume_retry_in_ms: idle_evidence.auto_resume_retry_in_ms,
      dispatch_hold_reason: idle_evidence.dispatch_hold_reason,
      capacity_hold_active?: idle_evidence.capacity_hold_active?,
      pause_reason: pause_reason,
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health
    }
  end

  defp idle_evidence(%State{} = state, issue, latch_status, open_decision_count, now_ms) do
    auto_resume_retry_in_ms = AutoResume.retry_in_ms(state, Map.get(issue, :id), now_ms)
    dispatch_hold_reason = Map.get(state.dispatch_hold || %{}, :reason)
    capacity_hold_active? = capacity_hold_active?(state)

    %{
      dispatch_latch: latch_status,
      auto_resume_retry_in_ms: auto_resume_retry_in_ms,
      dispatch_hold_reason: dispatch_hold_reason,
      capacity_hold_active?: capacity_hold_active?,
      waiting_reason:
        WaitingReason.for_idle(
          Map.get(issue, :state),
          DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, DispatchPolicy.terminal_state_set()),
          open_decision_count,
          latched_lifetime: latch_status != :none,
          tracker_paused: Issue.paused?(issue),
          auto_resume_retry_in_ms: auto_resume_retry_in_ms,
          dispatch_hold_reason: dispatch_hold_reason,
          capacity_hold_active?: capacity_hold_active?
        )
    }
  end

  defp track_waiting_for_human_episodes(%State{} = state, statuses, now) do
    current =
      statuses
      |> Enum.filter(&human_wait_alert_candidate?/1)
      |> Map.new(fn status -> {status.identifier, status} end)

    Enum.each(state.waiting_for_human_episodes, fn {identifier, episode} ->
      if not Map.has_key?(current, identifier) and episode.alerted?,
        do: emit_waiting_for_human_resolution(identifier)
    end)

    episodes =
      Enum.reduce(current, %{}, fn {identifier, _status}, acc ->
        episode = Map.get(state.waiting_for_human_episodes, identifier, %{since: now, alerted?: false})
        elapsed = DateTime.diff(now, episode.since, :second)

        episode =
          if waiting_for_human_alert_due?(episode.since, now) and not episode.alerted? do
            maybe_emit_waiting_for_human_alert(identifier, elapsed)
            %{episode | alerted?: true}
          else
            episode
          end

        Map.put(acc, identifier, episode)
      end)

    %{state | waiting_for_human_episodes: episodes}
  end

  @doc false
  @spec waiting_for_human_alert_due?(DateTime.t(), DateTime.t()) :: boolean()
  def waiting_for_human_alert_due?(%DateTime{} = since, %DateTime{} = now) do
    DateTime.diff(now, since, :second) >= @waiting_for_human_alert_after_seconds
  end

  defp human_wait_alert_candidate?(%{waiting_reason: :waiting_for_human} = status) do
    (is_integer(status.open_decision_count) and status.open_decision_count > 0) or
      status.pause_reason in [:agent_pause_request, :input_required]
  end

  defp human_wait_alert_candidate?(_status), do: false

  defp emit_waiting_for_human_resolution(identifier) do
    Alerts.emit_system("ticket.#{identifier}.agent.attention.waiting_for_human.resolved",
      issue: identifier,
      reason: "Agent is no longer waiting for Executor input.",
      needs_attention: false,
      severity: "info",
      central: true
    )
  end

  defp maybe_emit_waiting_for_human_alert(identifier, runtime_seconds)
       when is_binary(identifier) and is_integer(runtime_seconds) do
    topic = "ticket.#{identifier}.agent.attention.waiting_for_human"

    unless AlertFeed.active_ticket_attention?(topic) do
      Alerts.emit_system(topic,
        issue: identifier,
        reason: "Agent has been waiting for Executor input for #{div(runtime_seconds, 60)}m; answer the blocking question or resume the agent.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end

  defp idle_status_reason(
         _work_state,
         _pause_reason,
         _prewarm_blocked?,
         _budget,
         _max_dispatches,
         _latch_status,
         cause,
         retry_in_ms
       )
       when not is_nil(cause),
       do: StatusReason.for_claim_release(cause, retry_in_ms)

  defp idle_status_reason(
         _work_state,
         _pause_reason,
         _prewarm_blocked?,
         _budget,
         _max_dispatches,
         {:lifetime, lifetime, maximum},
         _cause,
         _retry_in_ms
       ),
       do: StatusReason.for_idle(false, :lifetime, lifetime, maximum)

  defp idle_status_reason(
         :paused,
         pause_reason,
         _prewarm_blocked?,
         _budget,
         _max_dispatches,
         :none,
         _cause,
         _retry_in_ms
       ),
       do: StatusReason.for_pause(pause_reason)

  defp idle_status_reason(
         _work_state,
         _pause_reason,
         prewarm_blocked?,
         budget,
         max_dispatches,
         :none,
         _cause,
         _retry_in_ms
       ) do
    StatusReason.for_idle(
      prewarm_blocked?,
      Map.get(budget, :tripped),
      Map.get(budget, :lifetime, 0),
      max_dispatches
    )
  end

  @doc false
  # A status projection must never wait behind a base build or crash while the
  # RepoBase process is restarting. Treat a timeout or process exit as an
  # unavailable snapshot; dispatch admission remains the authoritative gate.
  @spec prewarm_phase((timeout() -> term())) :: atom() | :unavailable
  def prewarm_phase(status_fun \\ &RepoBase.status/1) when is_function(status_fun, 1) do
    case status_fun.(@repo_base_status_timeout_ms) do
      {phase, _path} when is_atom(phase) -> phase
      _ -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp prewarm_blocked?(phase) when phase in [:cloning, :fetching, :building, :checking], do: true
  defp prewarm_blocked?(_phase), do: false

  defp idle_queue_depth(%State{} = state, identifier) when is_binary(identifier) do
    OM.queue_depth_for_issue(state, identifier)
  end

  defp idle_queue_depth(_state, _identifier), do: 0

  defp retry_snapshot_tracker_identity(retry, nil), do: Map.get(retry, :tracker_identity)
  defp retry_snapshot_tracker_identity(_retry, issue), do: Issue.tracker_identity(issue)

  # Distinguishes "this issue has no upstreams" from "we never resolved this
  # issue". Only the first is an empty list; the second is `nil`, which
  # `StreamDeckGrid.dependency_ready?/2` treats as blocking. Defaulting the
  # unknown case to `[]` would read as "no dependencies" and render the key
  # `Unblocked` — the same fail-open this projection exists to remove.
  defp known_blocked_by(%Issue{blocked_by: blockers}) when is_list(blockers), do: blockers
  defp known_blocked_by(_issue), do: nil

  defp idle_issue_work_state(%Issue{} = issue) do
    if Issue.paused?(issue), do: :paused, else: :idle
  end

  defp idle_issue_work_state(_issue), do: :idle

  defp idle_issue_pause_reason(%Issue{} = issue) do
    if Issue.paused?(issue), do: :label_override, else: nil
  end

  defp idle_issue_pause_reason(_issue), do: nil

  # A ticket with no running entry (idle or awaiting retry) carries no local
  # pause cause, so the tracker label is normally the whole story. A fleet-wide
  # pause is the one cause that is still knowable, and it explains the stall far
  # better than rendering every such row as an operator pause.
  defp tracker_pause_cause(%State{globally_paused: true}), do: :global_pause
  defp tracker_pause_cause(_state), do: :label_override

  @spec next_poll_in_ms(integer() | nil, integer()) :: non_neg_integer() | nil
  def next_poll_in_ms(nil, _now_ms), do: nil

  def next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end
end
