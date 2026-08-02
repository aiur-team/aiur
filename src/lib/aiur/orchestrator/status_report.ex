defmodule Aiur.Orchestrator.StatusReport do
  @moduledoc """
  Owns orchestrator StatusReport behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentEvents, AgentPubSub, AgentQueueStore, CodingAgent, Config, Issue, TicketActivity, TrackerIdentity}
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Lifecycle
  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.WaitingReason

  @activity_snapshot_timeout_ms 100

  @spec snapshot_api() :: map() | :timeout | :unavailable
  def snapshot_api, do: snapshot_api(Aiur.Orchestrator, 15_000)

  @spec snapshot_api(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot_api(server, timeout), do: status_api_call(server, :snapshot, timeout, true)

  @spec status_api() :: [map()] | :timeout | :unavailable
  def status_api, do: status_api(Aiur.Orchestrator, 5_000)

  @spec status_api(GenServer.server(), timeout()) :: [map()] | :timeout | :unavailable
  def status_api(server, timeout), do: status_api_call(server, :status, timeout, true)

  @spec poll_status_api() :: map() | :unavailable
  def poll_status_api, do: poll_status_api(Aiur.Orchestrator, 1_000)

  @spec poll_status_api(GenServer.server(), timeout()) :: map() | :unavailable
  def poll_status_api(server, timeout),
    do: status_api_call(server, :poll_status, timeout, false)

  @spec list_active_identifiers_api(GenServer.server(), timeout()) :: [String.t()]
  def list_active_identifiers_api(server, timeout) do
    if Process.whereis(server) do
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
    # Projection may call other stores, so run it in SnapshotStore rather than
    # extending the Orchestrator's dispatch critical path. Project only the
    # bounded dashboard input, not the entire orchestration state.
    SnapshotStore.publish_state(
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
      :effective_concurrent_agents,
      :globally_paused,
      :last_polled_issues,
      :load_envelope_state,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :poll_interval_ms,
      :retry_attempts,
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
      rewakes: %{}
    }
  end

  # A dashboard can show a pending control only for a running issue. Preserve
  # those records, not the full bounded-but-fleet-wide control history.
  defp snapshot_control_lifecycle(%State{} = state) do
    Enum.reduce(state.running, %ControlLifecycle{}, fn {_issue_id, entry}, lifecycle ->
      issue_id = entry |> Map.get(:issue, %{}) |> Map.get(:id)

      case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
        %{request_id: request_id} = request ->
          %{
            lifecycle
            | pending: Map.put(lifecycle.pending, issue_id, request_id),
              records: Map.put(lifecycle.records, request_id, request)
          }

        nil ->
          lifecycle
      end
    end)
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
  def status(%State{} = state), do: {:reply, agent_statuses(state), state}

  @spec snapshot(State.t()) :: {:reply, map(), State.t()}
  def snapshot(%State{} = state) do
    state = Lifecycle.refresh_runtime_config(state)

    {:reply, snapshot_payload(state), state}
  end

  @doc false
  @spec snapshot_payload(State.t()) :: map()
  def snapshot_payload(%State{} = state) do
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    stall_timeout_seconds = stall_timeout_seconds()
    activity_by_identity = activity_by_identity()

    running = Enum.map(state.running, &running_snapshot(state, &1, now, stall_timeout_seconds, activity_by_identity))
    retrying = Enum.map(state.retry_attempts, &retry_snapshot(state, &1, now_ms, activity_by_identity))
    idle = idle_snapshot(state, activity_by_identity)

    %{
      running: running,
      retrying: retrying,
      idle: idle,
      agent_totals: state.agent_totals,
      capacity: Slots.max_concurrent_agent_status(state),
      globally_paused: state.globally_paused == true,
      rate_limits: Map.get(state, :agent_rate_limits),
      polling: %{
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms
      }
    }
  end

  defp running_snapshot(%State{} = state, {issue_id, metadata}, now, stall_timeout_seconds, activity_by_identity) do
    capabilities = OM.issue_control_capabilities(state, metadata.identifier)
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
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(metadata.issue, :priority),
      progress_percent: progress_percent(Issue.tracker_identity(metadata.issue), activity_by_identity),
      ci_result: cached_ci_result(state, metadata.identifier)
    }
    |> Map.merge(running_execution_facts(metadata))
  end

  defp retry_snapshot(%State{} = state, {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry}, now_ms, activity_by_identity) do
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
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(issue || %{}, :priority) || Map.get(retry, :priority),
      progress_percent: progress_percent(tracker_identity, activity_by_identity),
      ci_result: cached_ci_result(state, identifier)
    }
    |> Map.merge(issue_execution_facts(issue))
  end

  defp idle_snapshot(%State{} = state, activity_by_identity) do
    running_issue_ids = MapSet.new(Map.keys(state.running))

    # Also exclude issues already shown in the retry-backoff bucket — they're
    # tracker-active (still in `last_polled_issues`) but not in `running`,
    # so without this they'd double up as a contradictory second row here.
    retrying_issue_ids = MapSet.new(Map.keys(state.retry_attempts))

    excluded_issue_ids = MapSet.union(running_issue_ids, retrying_issue_ids)
    terminal_states = DispatchPolicy.terminal_state_set()

    state.last_polled_issues
    |> Enum.reject(fn {issue_id, _issue} -> MapSet.member?(excluded_issue_ids, issue_id) end)
    |> Enum.map(fn {_issue_id, issue} -> idle_issue_snapshot(state, issue, terminal_states, activity_by_identity) end)
  end

  defp idle_issue_snapshot(%State{} = state, %Issue{} = issue, terminal_states, activity_by_identity) do
    identifier = issue.identifier || issue.id
    blocked_by_open? = DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)

    %{
      issue_id: issue.id,
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: issue.state,
      tag: State.issue_tag(issue),
      title: issue.title,
      url: issue.url,
      tracker_paused: Issue.paused?(issue),
      queue_depth: OM.queue_depth_for_issue(state, identifier),
      waiting_reason: WaitingReason.for_idle(issue.state, blocked_by_open?, open_decision_count),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(issue, :priority),
      progress_percent: progress_percent(Issue.tracker_identity(issue), activity_by_identity),
      ci_result: cached_ci_result(state, identifier)
    }
    |> Map.merge(issue_execution_facts(issue))
  end

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

  defp activity_by_identity do
    with pid when is_pid(pid) <- Process.whereis(TicketActivity),
         %{entries: entries} when is_list(entries) <- TicketActivity.snapshots(timeout: @activity_snapshot_timeout_ms) do
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

  defp progress_percent(identity, activity_by_identity) do
    case get_in(activity_by_identity, [TrackerIdentity.github_key(identity), :progress]) do
      %{freshness: :fresh, percent: percent} when is_integer(percent) and percent in 0..100 -> percent
      _ -> 0
    end
  end

  defp status_api_call(server, request, timeout, distinguish_timeout?) do
    if Process.whereis(server) do
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
    issue = Map.get(entry, :issue)
    running_summary(identifier, entry, State.issue_tag(issue), get_in(entry, [:issue, Access.key(:title)]), now)
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

  @spec agent_statuses(State.t()) :: [map()]
  def agent_statuses(%State{} = state) do
    now = DateTime.utc_now()

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    (running_statuses(state, now) ++ idle_statuses(state, running_by_identifier))
    |> Enum.sort_by(fn status -> to_string(status.identifier || status.issue_id || "") end)
  end

  defp running_statuses(%State{} = state, %DateTime{} = now) do
    Enum.map(state.running, fn {issue_id, entry} ->
      running_status(state, issue_id, entry, now)
    end)
  end

  defp running_status(%State{} = state, issue_id, entry, now) do
    identifier = Map.get(entry, :identifier) || issue_id
    issue = Map.get(entry, :issue)
    work_state = get_in(entry, [:control, :status]) || :working

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
      queue_depth: OM.queue_depth_for_issue(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
      last_codex_message: Map.get(entry, :last_codex_message),
      last_codex_event: Map.get(entry, :last_codex_event)
    }
  end

  defp idle_statuses(%State{} = state, _running_by_identifier) do
    state.last_polled_issues
    |> Enum.reject(fn {issue_id, _issue} -> Map.has_key?(state.running, issue_id) end)
    |> Enum.map(fn {_issue_id, issue} -> idle_status(state, issue) end)
  end

  defp idle_status(%State{} = state, issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, :id)

    %{
      issue_id: Map.get(issue, :id),
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: :idle,
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
      last_codex_event: nil
    }
  end

  defp idle_queue_depth(%State{} = state, identifier) when is_binary(identifier) do
    OM.queue_depth_for_issue(state, identifier)
  end

  defp idle_queue_depth(_state, _identifier), do: 0

  defp retry_snapshot_tracker_identity(retry, nil), do: Map.get(retry, :tracker_identity)
  defp retry_snapshot_tracker_identity(_retry, issue), do: Issue.tracker_identity(issue)

  defp idle_issue_work_state(%Issue{} = issue) do
    if Issue.paused?(issue), do: :paused, else: :idle
  end

  defp idle_issue_work_state(_issue), do: :idle

  defp idle_issue_pause_reason(%Issue{} = issue) do
    if Issue.paused?(issue), do: :label_override, else: nil
  end

  defp idle_issue_pause_reason(_issue), do: nil

  @spec next_poll_in_ms(integer() | nil, integer()) :: non_neg_integer() | nil
  def next_poll_in_ms(nil, _now_ms), do: nil

  def next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end
end
