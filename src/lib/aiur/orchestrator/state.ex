defmodule Aiur.Orchestrator.State do
  @moduledoc """
  Runtime state for the orchestrator polling loop.
  """

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Orchestrator.{PauseResume, StatusReport}

  @type t :: %__MODULE__{
          poll_interval_ms: integer() | nil,
          max_concurrent_agents: integer() | nil,
          session_max_concurrent_agents: integer() | nil,
          effective_concurrent_agents: integer() | nil,
          load_envelope_last_decrease_ms: integer() | nil,
          next_poll_due_at_ms: integer() | nil,
          poll_check_in_progress: boolean() | nil,
          tick_timer_ref: reference() | nil,
          tick_token: reference() | nil,
          initial_dispatch_cycle: boolean() | nil,
          queue_store: term(),
          last_polled_issues: map(),
          ci_lifecycle: %{
            approved_heads: map(),
            test_failure_heads: map(),
            poll_cache: map(),
            rewakes: map()
          },
          todo_over_capacity_alert_active: boolean(),
          running: map(),
          completed: MapSet.t(),
          claimed: MapSet.t(),
          retry_attempts: map(),
          codex_thrash_budget: map(),
          model_fallback_waiting: MapSet.t(),
          agent_totals: map() | nil,
          agent_rate_limits: map() | nil,
          codex_totals: map() | nil,
          codex_rate_limits: map() | nil,
          events_etag: String.t() | nil,
          events_last_id: String.t() | nil,
          recent_merge_persistence_failures: non_neg_integer(),
          recent_merge_persistence_alerted?: boolean(),
          github_comments_since: String.t() | map() | nil,
          github_comment_issue_updated_at: map(),
          github_command_scan_since: String.t() | nil,
          github_connectivity: map(),
          github_poll_delays: map()
        }

  defstruct [
    :poll_interval_ms,
    :max_concurrent_agents,
    :session_max_concurrent_agents,
    :effective_concurrent_agents,
    :load_envelope_last_decrease_ms,
    :next_poll_due_at_ms,
    :poll_check_in_progress,
    :tick_timer_ref,
    :tick_token,
    :initial_dispatch_cycle,
    queue_store: AgentQueueStore.new(),
    last_polled_issues: %{},
    ci_lifecycle: %{approved_heads: %{}, test_failure_heads: %{}, poll_cache: %{}, rewakes: %{}},
    todo_over_capacity_alert_active: false,
    running: %{},
    completed: MapSet.new(),
    claimed: MapSet.new(),
    retry_attempts: %{},
    codex_thrash_budget: %{},
    model_fallback_waiting: MapSet.new(),
    agent_totals: nil,
    agent_rate_limits: nil,
    codex_totals: nil,
    codex_rate_limits: nil,
    events_etag: nil,
    events_last_id: nil,
    recent_merge_persistence_failures: 0,
    recent_merge_persistence_alerted?: false,
    github_comments_since: nil,
    github_comment_issue_updated_at: %{},
    github_command_scan_since: nil,
    github_connectivity: %{},
    github_poll_delays: %{}
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

        StatusReport.notify_dashboard(state)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

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
    not (paused_running_entry?(entry) or deactivated_running_entry?(entry))
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
  # (operator resume -> fresh budget, automated resume -> preserve overrun),
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
