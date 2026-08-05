defmodule Aiur.Orchestrator.State do
  @moduledoc """
  Runtime state for the orchestrator polling loop.
  """

  alias Aiur.{AgentQueueStore, Issue, TrackerIdentity}
  alias Aiur.LiveConversation.Source, as: LiveConversationSource
  alias Aiur.Orchestrator.{ControlLifecycle, PauseResume, StatusReport}

  @default_dispatch_recovery %{
    workspace_ownership: %{waits: %{}, ready: %{}},
    codex_thrash_budget: %{}
  }

  @type t :: %__MODULE__{
          poll_interval_ms: integer() | nil,
          snapshot_key: GenServer.server() | nil,
          snapshot_generation: reference() | nil,
          snapshot_ready?: boolean(),
          max_concurrent_agents: integer() | nil,
          session_max_concurrent_agents: integer() | nil,
          effective_concurrent_agents: integer() | nil,
          load_envelope_state: %{
            last_decrease_ms: integer() | nil,
            cpu_snapshot: Aiur.SystemCpu.snapshot() | nil
          },
          capacity_hold:
            %{
              signal: :memory | :file_descriptors | :run_queue | :load | :build | :provider | :envelope,
              measured: term(),
              threshold: term(),
              held_since_ms: integer(),
              alerted?: boolean()
            }
            | nil,
          next_poll_due_at_ms: integer() | nil,
          poll_check_in_progress: boolean() | nil,
          poll_frozen: boolean() | nil,
          tick_timer_ref: reference() | nil,
          tick_token: reference() | nil,
          initial_dispatch_cycle: boolean() | nil,
          queue_store: term(),
          last_polled_issues: map(),
          ci_lifecycle: %{
            approved_heads: map(),
            test_failure_heads: map(),
            base_repair_invalidations: map(),
            poll_cache: map(),
            rewakes: map()
          },
          todo_over_capacity_alert_active: boolean(),
          prewarm_blocked_alert_active: boolean(),
          prewarm_blocked_alert_resolution_emitted: boolean(),
          tracker_preflight_alert_signature: String.t() | nil,
          tracker_preflight_alert_resolution_emitted: boolean(),
          capacity_starvation_resolution_emitted: boolean(),
          observed_error_alerts: MapSet.t(),
          active_attention_topics: MapSet.t(),
          observed_error_alert_causes: %{optional(String.t()) => atom()},
          dispatch_capacity_constraints: [map()],
          capacity_starvation: %{
            since_ms: %{optional(String.t()) => integer()},
            alert_active: boolean(),
            signature: [String.t()],
            alerted: [String.t()]
          },
          running: map(),
          completed: MapSet.t(),
          claimed: MapSet.t(),
          dispatch_recovery: %{
            workspace_ownership: %{waits: map(), ready: map()},
            codex_thrash_budget: map()
          },
          retry_attempts: map(),
          # Transient-caused pause/error tickets waiting a bounded backoff before
          # automatic re-dispatch (#1453). Keyed by issue_id; see
          # `Aiur.Orchestrator.AutoResume`.
          auto_resume: %{String.t() => map()},
          model_fallback_waiting: MapSet.t(),
          agent_totals: map() | nil,
          agent_rate_limits: map() | nil,
          codex_totals: map() | nil,
          codex_rate_limits: map() | nil,
          events_etag: String.t() | nil,
          events_last_id: String.t() | nil,
          github_comments_since: String.t() | map() | nil,
          github_comment_etags: map(),
          github_comment_issue_updated_at: map(),
          github_command_scan_since: String.t() | nil,
          github_connectivity: map(),
          github_poll_delays: map(),
          globally_paused: boolean(),
          ci_readiness_checked: boolean() | nil,
          ci_readiness_unavailable_alerted: boolean() | nil,
          ci_readiness_check_pid: pid() | nil,
          ci_readiness_check_token: reference() | nil,
          ci_readiness_retry_at_ms: integer() | nil,
          ci_readiness_scope: {String.t(), String.t(), String.t()} | nil,
          ci_readiness_result: Aiur.GitHub.CiReadiness.result() | nil,
          global_pause: %{paused_at: DateTime.t() | nil, source: String.t() | nil},
          control_lifecycle: ControlLifecycle.t(),
          # Consecutive poll ticks the prewarm gate has held dispatch for a
          # warming base. Drives the at-most-once-per-N-ticks hold log so a
          # slow/stuck base build stays visible in the daemon log without
          # spamming it (see Dispatcher.log_prewarm_hold/2).
          prewarm_hold_ticks: non_neg_integer()
        }

  # The Orchestrator is the single owner of the correlated control lifecycle;
  # keeping that aggregate here avoids a second process/state authority.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :poll_interval_ms,
    :snapshot_key,
    :snapshot_generation,
    :max_concurrent_agents,
    :session_max_concurrent_agents,
    :effective_concurrent_agents,
    :next_poll_due_at_ms,
    :poll_check_in_progress,
    :poll_frozen,
    :tick_timer_ref,
    :tick_token,
    :initial_dispatch_cycle,
    :ci_readiness_checked,
    :ci_readiness_unavailable_alerted,
    :ci_readiness_check_pid,
    :ci_readiness_check_token,
    :ci_readiness_retry_at_ms,
    :ci_readiness_scope,
    :ci_readiness_result,
    load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil},
    capacity_hold: nil,
    queue_store: AgentQueueStore.new(),
    last_polled_issues: %{},
    ci_lifecycle: %{
      approved_heads: %{},
      test_failure_heads: %{},
      base_repair_invalidations: %{},
      poll_cache: %{},
      rewakes: %{}
    },
    todo_over_capacity_alert_active: false,
    prewarm_blocked_alert_active: false,
    prewarm_blocked_alert_resolution_emitted: false,
    tracker_preflight_alert_signature: nil,
    tracker_preflight_alert_resolution_emitted: false,
    capacity_starvation_resolution_emitted: false,
    observed_error_alerts: MapSet.new(),
    active_attention_topics: MapSet.new(),
    observed_error_alert_causes: %{},
    dispatch_capacity_constraints: [],
    capacity_starvation: %{since_ms: %{}, alert_active: false, signature: [], alerted: []},
    running: %{},
    completed: MapSet.new(),
    claimed: MapSet.new(),
    dispatch_recovery: @default_dispatch_recovery,
    retry_attempts: %{},
    auto_resume: %{},
    model_fallback_waiting: MapSet.new(),
    agent_totals: nil,
    agent_rate_limits: nil,
    codex_totals: nil,
    codex_rate_limits: nil,
    events_etag: nil,
    events_last_id: nil,
    github_comments_since: nil,
    github_comment_etags: %{},
    github_comment_issue_updated_at: %{},
    github_command_scan_since: nil,
    github_connectivity: %{},
    github_poll_delays: %{},
    globally_paused: false,
    global_pause: %{paused_at: nil, source: nil},
    snapshot_ready?: false,
    control_lifecycle: %ControlLifecycle{},
    prewarm_hold_ticks: 0
  ]

  @spec handle_worker_runtime_info(t(), String.t(), map()) :: {:noreply, t()}
  def handle_worker_runtime_info(%__MODULE__{running: running} = state, issue_id, runtime_info)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_live_conversation(runtime_info[:live_conversation])

        if updated_running_entry == running_entry do
          {:noreply, state}
        else
          next_state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
          StatusReport.notify_dashboard(next_state)
          {:noreply, next_state}
        end
    end
  end

  @spec handle_live_conversation_restart(t(), String.t(), DateTime.t()) :: {:noreply, t()}
  def handle_live_conversation_restart(%__MODULE__{} = state, projection_epoch, observed_at)
      when is_binary(projection_epoch) and is_struct(observed_at, DateTime) do
    running =
      Map.new(state.running, fn {issue_id, entry} ->
        generation = get_in(entry, [:control, :generation])

        status = %{
          projection_epoch: projection_epoch,
          revision: 0,
          source_revision: 0,
          generation_handle: nil,
          source: nil,
          state: :restart_unknown,
          health: :unknown,
          freshness: :unknown,
          observed_at: observed_at
        }

        fence = %{
          projection_epoch: projection_epoch,
          revision: 0,
          source_revision: 0,
          source: nil,
          worker_generation: generation,
          restart_locked?: true
        }

        {issue_id,
         entry
         |> Map.put(:live_conversation, status)
         |> Map.put(:live_conversation_fence, fence)}
      end)

    next_state = %{state | running: running}

    if next_state == state do
      {:noreply, state}
    else
      StatusReport.notify_dashboard(next_state)
      {:noreply, next_state}
    end
  end

  def handle_live_conversation_restart(%__MODULE__{} = state, _projection_epoch, _observed_at),
    do: {:noreply, state}

  @spec handle_repl_session_runtime(t(), String.t(), map()) :: {:noreply, t()}
  def handle_repl_session_runtime(%__MODULE__{running: running} = state, issue_id, info)
      when is_binary(issue_id) and is_map(info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:repl_pane_id, info[:pane_id])
          |> maybe_put_runtime_value(:repl_os_pid, info[:os_pid])
          |> maybe_put_runtime_value(:headless_os_pid, info[:headless_os_pid])
          |> maybe_put_runtime_value(:repl_rc_session_url, info[:session_url])

        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  @spec handle_session_execution_info(t(), String.t(), map()) :: {:noreply, t()}
  def handle_session_execution_info(
        %__MODULE__{running: running} = state,
        issue_id,
        %{backend: backend} = info
      )
      when is_binary(issue_id) and is_binary(backend) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        session_execution = %{
          backend: backend,
          requested_model: optional_runtime_string(info[:requested_model]),
          effort: optional_runtime_string(info[:effort])
        }

        updated_state =
          %{state | running: Map.put(running, issue_id, Map.put(running_entry, :session_execution, session_execution))}

        StatusReport.notify_dashboard(updated_state)
        {:noreply, updated_state}
    end
  end

  @spec note_agent_activity(t(), String.t()) :: t()
  # Claude hook activity is the liveness signal for backends without codex updates.
  def note_agent_activity(%__MODULE__{} = state, identifier) when is_binary(identifier) do
    case find_running_key_by_identifier(state.running, identifier) do
      nil ->
        state

      issue_id ->
        update_in(
          state.running,
          &PauseResume.reset_last_codex_timestamp(&1, issue_id, DateTime.utc_now())
        )
    end
  end

  @spec alive?(term()) :: boolean()
  def alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  def alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  def alive?({:via, _, _}), do: true
  def alive?({:global, _}), do: true
  def alive?(_), do: false

  @spec maybe_put_runtime_value(term(), term(), term()) :: term()
  def maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  def maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp optional_runtime_string(value) when is_binary(value), do: value
  defp optional_runtime_string(_value), do: nil

  defp maybe_put_live_conversation(running_entry, nil), do: running_entry

  defp maybe_put_live_conversation(running_entry, status) do
    with %{} = status <- live_conversation_runtime(status),
         true <- authoritative_live_conversation_status?(running_entry, status) do
      fence = %{
        projection_epoch: status.projection_epoch,
        revision: status.revision,
        source_revision: status.source_revision,
        source: status.source,
        worker_generation: status.source.worker_generation,
        restart_locked?: false
      }

      running_entry
      |> Map.put(:live_conversation, status)
      |> Map.put(:live_conversation_fence, fence)
    else
      _invalid_or_stale -> running_entry
    end
  end

  defp live_conversation_runtime(%{} = status) do
    if valid_runtime_identity?(status) and valid_runtime_revisions?(status) and
         valid_runtime_enums?(status) and is_struct(Map.get(status, :observed_at), DateTime) do
      Map.take(status, [
        :projection_epoch,
        :revision,
        :source_revision,
        :generation_handle,
        :source,
        :state,
        :health,
        :freshness,
        :observed_at
      ])
    end
  end

  defp live_conversation_runtime(_status), do: nil

  defp valid_runtime_identity?(status) do
    valid_projection_epoch?(Map.get(status, :projection_epoch)) and
      valid_conversation_handle?(Map.get(status, :generation_handle)) and
      valid_conversation_source?(Map.get(status, :source))
  end

  defp valid_runtime_revisions?(status) do
    revision = Map.get(status, :revision)
    source_revision = Map.get(status, :source_revision)

    is_integer(revision) and revision > 0 and is_integer(source_revision) and
      source_revision > 0 and source_revision <= revision
  end

  defp valid_runtime_enums?(status) do
    Map.get(status, :state) in [:live, :ended, :known_empty, :stale, :unavailable, :restart_unknown] and
      Map.get(status, :health) in [:healthy, :unavailable, :unknown] and
      Map.get(status, :freshness) in [:current, :stale, :unknown]
  end

  defp authoritative_live_conversation_status?(running_entry, status) do
    expected_generation = get_in(running_entry, [:control, :generation])

    status.source.worker_generation == expected_generation and
      matching_live_identity?(running_entry, status.source.identity) and
      newer_live_conversation_status?(running_entry, status)
  end

  defp matching_live_identity?(running_entry, identity) do
    case Issue.tracker_identity(Map.get(running_entry, :issue)) do
      %{kind: kind, owner: owner, repository: repository, identifier: identifier} ->
        identity == %{
          version: 1,
          kind: kind,
          owner: owner,
          repository: repository,
          identifier: identifier
        }

      _missing ->
        false
    end
  end

  defp newer_live_conversation_status?(running_entry, status) do
    case Map.get(running_entry, :live_conversation_fence) do
      nil ->
        true

      %{projection_epoch: epoch} when epoch != status.projection_epoch ->
        false

      %{restart_locked?: true} ->
        status.state == :ended

      %{revision: revision} when status.revision <= revision ->
        false

      %{source: source, source_revision: source_revision} ->
        source == status.source or status.source_revision > source_revision

      _invalid_fence ->
        false
    end
  end

  defp valid_projection_epoch?("projection:" <> digest) do
    byte_size(digest) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, digest)
  end

  defp valid_projection_epoch?(_epoch), do: false

  defp valid_conversation_handle?(handle), do: LiveConversationSource.valid_handle?(handle)

  defp valid_conversation_source?(%{
         identity: %{
           version: 1,
           kind: :github,
           owner: owner,
           repository: repository,
           identifier: identifier
         },
         run_id: run_id,
         attempt_id: attempt_id,
         session_id: session_id,
         backend: backend,
         worker_generation: generation
       }) do
    Enum.all?([owner, repository, identifier, run_id, attempt_id, backend], &valid_runtime_field?/1) and
      valid_runtime_session?(session_id) and is_integer(generation) and generation > 0
  end

  defp valid_conversation_source?(_source), do: false

  defp valid_runtime_session?(nil), do: true

  defp valid_runtime_session?("session:" <> digest) do
    byte_size(digest) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, digest)
  end

  defp valid_runtime_session?(_session), do: false

  defp valid_runtime_field?(field), do: is_binary(field) and field != "" and byte_size(field) <= 256

  @spec find_issue_id_for_ref(map(), term()) :: term() | nil
  def find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  @spec running_entry_session_id(term()) :: String.t()
  def running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  def running_entry_session_id(_running_entry), do: "n/a"

  @spec issue_context(Issue.t()) :: String.t()
  def issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @spec active_running_count(term()) :: non_neg_integer()
  def active_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, entry} -> active_running_entry?(entry)
    end)
  end

  def active_running_count(_running), do: 0

  @spec paused_running_count(term()) :: non_neg_integer()
  def paused_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, entry} -> paused_running_entry?(entry)
    end)
  end

  def paused_running_count(_running), do: 0

  @spec reserved_paused_running_count(term()) :: non_neg_integer()
  def reserved_paused_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, %{paused_reason: :ci_wait}} -> false
      {_issue_id, entry} -> paused_running_entry?(entry)
    end)
  end

  def reserved_paused_running_count(_running), do: 0

  @spec active_running_entry?(term()) :: boolean()
  def active_running_entry?(entry) when is_map(entry) do
    not (completed_running_entry?(entry) or paused_running_entry?(entry) or
           deactivated_running_entry?(entry))
  end

  def active_running_entry?(_entry), do: false

  @spec paused_running_entry?(term()) :: boolean()
  def paused_running_entry?(entry) when is_map(entry) do
    (get_in(entry, [:control, :status]) || :working) == :paused
  end

  def paused_running_entry?(_entry), do: false

  @spec sleeping_running_entry?(term()) :: boolean()
  def sleeping_running_entry?(entry) when is_map(entry) do
    (get_in(entry, [:control, :status]) || :working) == :sleeping
  end

  def sleeping_running_entry?(_entry), do: false

  @spec completed_running_entry?(term()) :: boolean()
  def completed_running_entry?(entry) when is_map(entry) do
    get_in(entry, [:control, :status]) == :completed
  end

  def completed_running_entry?(_entry), do: false

  @spec completed_provenance?(term()) :: boolean()
  def completed_provenance?(entry) when is_map(entry) do
    completed_running_entry?(entry) or Map.get(entry, :completed_provenance) == true
  end

  def completed_provenance?(_entry), do: false

  @spec deactivated_running_entry?(term()) :: boolean()
  def deactivated_running_entry?(entry) when is_map(entry) do
    get_in(entry, [:control, :status]) == :deactivated
  end

  def deactivated_running_entry?(_entry), do: false

  @spec find_running_key_by_identifier(map(), String.t()) :: term() | nil
  def find_running_key_by_identifier(running, identifier) do
    Enum.find_value(running, fn
      {issue_id, %{identifier: id}} -> if to_string(id) == identifier, do: issue_id, else: nil
      _ -> nil
    end)
  end

  # Freeze the runtime clock while the agent is paused and shift
  # `started_at` forward on resume so `now - started_at` excludes the
  # paused interval. The age column in the agent list (and any other
  # consumer of `running_seconds/2`) stops advancing while paused.
  @spec apply_pause_runtime_clock(map(), atom(), atom(), term()) :: map()
  def apply_pause_runtime_clock(entry, :working, :paused, now) when is_map(entry) do
    Map.put(entry, :paused_at, now)
  end

  def apply_pause_runtime_clock(entry, :paused, :working, now) when is_map(entry) do
    shift_started_at_by_pause(entry, now)
  end

  def apply_pause_runtime_clock(entry, _previous, _next, _now), do: entry

  @spec thaw_pause_clock(map(), term(), atom(), term()) :: map()
  def thaw_pause_clock(running, issue_id, previous_status, now) when is_map(running) do
    case Map.get(running, issue_id) do
      nil ->
        running

      entry ->
        Map.put(running, issue_id, shift_started_at_by_pause_if(entry, previous_status, now))
    end
  end

  @spec shift_started_at_by_pause_if(map(), atom(), term()) :: map()
  def shift_started_at_by_pause_if(entry, :paused, now),
    do: shift_started_at_by_pause(entry, now)

  def shift_started_at_by_pause_if(entry, _previous, _now), do: entry

  # A duration-capped pause is owned by `reset_duration_clock_if_capped/4`
  # (Executor resume -> fresh budget, automated resume -> preserve overrun),
  # so the thaw must only un-freeze the pause clock (clear `paused_at`) and
  # must NOT credit the paused interval back into `started_at`. Crediting it
  # would advance `started_at` toward now and silently reset the overrun on
  # an automated resume — the exact #420 leak. Other pauses keep the normal
  # "exclude the paused interval" shift.
  @spec shift_started_at_by_pause(map(), term()) :: map()
  def shift_started_at_by_pause(%{paused_reason: :max_agent_duration} = entry, %DateTime{}) do
    Map.put(entry, :paused_at, nil)
  end

  def shift_started_at_by_pause(%{paused_at: %DateTime{} = paused_at} = entry, %DateTime{} = now) do
    paused_for = max(0, DateTime.diff(now, paused_at, :second))

    entry
    |> Map.update(:started_at, nil, fn
      %DateTime{} = started_at -> DateTime.add(started_at, paused_for, :second)
      other -> other
    end)
    |> Map.put(:paused_at, nil)
  end

  def shift_started_at_by_pause(entry, _now), do: entry

  @spec issue_tag(term()) :: String.t() | nil
  def issue_tag(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Enum.find(fn label -> is_binary(label) and String.starts_with?(label, "agent:") end)
  end

  def issue_tag(_issue), do: nil

  @spec find_running_by_identifier(map(), String.t()) :: map() | nil
  def find_running_by_identifier(running, issue_identifier) do
    Enum.find_value(running, fn
      {_issue_id, %{identifier: identifier} = entry} ->
        if to_string(identifier) == issue_identifier, do: entry, else: nil

      _ ->
        nil
    end)
  end

  @doc false
  @spec find_unique_running_by_identity(map(), TrackerIdentity.t()) ::
          {:ok, map(), String.t()} | {:error, :no_running_agent | :ambiguous_identifier}
  def find_unique_running_by_identity(running, %TrackerIdentity{} = identity) when is_map(running) do
    identity_key = TrackerIdentity.github_key(identity)

    exact_matches =
      Enum.flat_map(running, fn
        {_issue_id, entry} when is_map(entry) ->
          if running_identity_key(entry) == identity_key and not is_nil(identity_key), do: [entry], else: []

        _entry ->
          []
      end)

    case exact_matches do
      [entry] -> unique_identifier_target(running, entry)
      _matches -> {:error, if(exact_matches == [], do: :no_running_agent, else: :ambiguous_identifier)}
    end
  end

  def find_unique_running_by_identity(_running, _identity), do: {:error, :no_running_agent}

  defp unique_identifier_target(running, entry) do
    identifier = entry |> Map.get(:identifier) |> to_string()

    matches =
      Enum.count(running, fn
        {_issue_id, %{identifier: candidate}} -> to_string(candidate) == identifier
        _entry -> false
      end)

    if identifier != "" and matches == 1,
      do: {:ok, entry, identifier},
      else: {:error, :ambiguous_identifier}
  end

  defp running_identity_key(entry) do
    identity =
      Map.get(entry, :tracker_identity) ||
        case Map.get(entry, :issue) do
          %Issue{} = issue -> Issue.tracker_identity(issue)
          _issue -> nil
        end

    TrackerIdentity.github_key(identity)
  end

  @spec find_running_by_repl_pane_id(map(), term()) :: map() | nil
  def find_running_by_repl_pane_id(running, pane_id) do
    Enum.find_value(running, fn
      {_issue_id, %{repl_pane_id: ^pane_id} = entry} -> entry
      _ -> nil
    end)
  end

  @spec pop_running_entry(t(), term()) :: {term(), t()}
  def pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  @spec running_seconds(term(), term()) :: non_neg_integer()
  def running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  def running_seconds(_started_at, _now), do: 0

  # Wall-clock seconds the agent has spent *actively working*. If the
  # entry is currently paused, the clock is frozen at the moment of
  # pause; on resume `shift_started_at_by_pause/2` shifts `started_at`
  # forward so any future delta excludes the paused interval.
  @spec effective_runtime_seconds(term(), DateTime.t()) :: non_neg_integer()
  def effective_runtime_seconds(entry, %DateTime{} = now) when is_map(entry) do
    case {Map.get(entry, :started_at), Map.get(entry, :paused_at)} do
      {%DateTime{} = started_at, %DateTime{} = paused_at} ->
        running_seconds(started_at, paused_at)

      {started_at, _} ->
        running_seconds(started_at, now)
    end
  end

  def effective_runtime_seconds(_entry, _now), do: 0
end
