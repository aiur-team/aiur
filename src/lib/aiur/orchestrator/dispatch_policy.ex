defmodule Aiur.Orchestrator.DispatchPolicy do
  @moduledoc """
  Pure dispatch, load-gate, and issue-candidate policy for the orchestrator.
  """

  alias Aiur.{Config, Issue, SystemLoad}
  alias Aiur.Orchestrator.{Slots, State}

  @doc false
  # Reads the host 1-min load only when the gate is enabled (threshold > 0), so
  # explicit-disable configs never touch /proc. Exposed for unit-testing the
  # short-circuit; the pure hold/dispatch decision is load_gate/3.
  @spec read_load(number() | nil) :: float() | :unavailable
  def read_load(threshold) when is_number(threshold) and threshold > 0, do: SystemLoad.avg1()
  def read_load(_threshold), do: :unavailable

  @doc false
  # Pure dispatch decision for the eager pre-warm gate, kept separate so it can be
  # unit-tested without the orchestrator GenServer.
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  def prewarm_gate(false, _phase), do: :dispatch
  def prewarm_gate(true, :ready), do: :dispatch
  def prewarm_gate(true, {:error, _reason}), do: :dispatch
  def prewarm_gate(true, _warming), do: :hold

  @doc false
  # Pure CPU load gate (#465), kept separate so it can be unit-tested without the
  # orchestrator GenServer. Holds new dispatch only when the 1-min load average
  # strictly exceeds `threshold` per scheduler; fails open (dispatch) when the
  # gate is disabled (nil/<=0 threshold) or the load is unavailable (non-Linux).
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  def load_gate(_load, nil, _schedulers), do: :dispatch
  def load_gate(_load, threshold, _schedulers) when threshold <= 0, do: :dispatch
  def load_gate(:unavailable, _threshold, _schedulers), do: :dispatch
  def load_gate(load, threshold, schedulers) when load > threshold * schedulers, do: :hold
  def load_gate(_load, _threshold, _schedulers), do: :dispatch

  @spec sort_issues_for_dispatch([term()]) :: [term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec priority_rank(term()) :: 1..5
  def priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  def priority_rank(_priority), do: 5

  @spec issue_created_at_sort_key(term()) :: integer()
  def issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  def issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  def issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  @spec should_dispatch_issue?(Issue.t(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    dispatch_candidate?(issue, state, active_states, terminal_states) and
      Slots.available_slots(state) > 0
  end

  def should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  # All dispatch preconditions except the global active+paused slot reservation.
  # Polling layers `available_slots > 0` on top of this to honor paused-agent
  # slot holds; manual start paths (e.g., space on a queued ticket) instead
  # gate on `active < max` so the operator can claim a free slot even when a
  # parallel paused agent is parked in the running map.
  @spec dispatch_candidate?(Issue.t(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def dispatch_candidate?(
        %Issue{} = issue,
        %State{running: running, claimed: claimed} = state,
        active_states,
        terminal_states
      ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      state_slots_available?(issue, state) and
      Slots.worker_slots_available?(state)
  end

  @spec state_slots_available?(term(), term()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, %State{} = state) do
    limit = effective_state_limit(issue_state, state)
    used = running_issue_count_for_state(state.running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _state), do: false

  # Per-state cap honors explicit overrides in
  # `agent.max_concurrent_agents_by_state` first, then falls back to the
  # *session-aware* global limit. Without this, bumping the global cap at
  # runtime (←/→ in the agent list) had no effect on dispatch eligibility
  # because the per-state default was pinned to the workflow file value.
  @spec effective_state_limit(term(), State.t()) :: pos_integer()
  def effective_state_limit(issue_state, %State{} = state) do
    config = Config.settings!()
    normalized = normalize_issue_state(issue_state)

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      normalized,
      Slots.max_concurrent_agent_limit(state)
    )
  end

  @spec running_issue_count_for_state(term(), term()) :: non_neg_integer()
  def running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}} = entry} ->
        normalize_issue_state(state_name) == normalized_state and State.active_running_entry?(entry)

      _ ->
        false
    end)
  end

  @spec candidate_issue?(term(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate_issue?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      issue_not_paused?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec issue_not_paused?(Issue.t()) :: boolean()
  def issue_not_paused?(%Issue{} = issue), do: not Issue.paused?(issue)

  @spec issue_routable_to_worker?(term()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  @spec todo_issue_blocked_by_non_terminal?(term(), MapSet.t()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec terminal_issue_state?(term(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @spec active_issue_state?(term(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  # Nil / non-binary state happens when the GitHub poll returns an
  # issue with no `agent:*` label — extract_state returns nil. Treat
  # as 'not active' so the reconcile cond falls through to the
  # catch-all instead of crashing the orchestrator GenServer.
  def active_issue_state?(_state_name, _active_states), do: false

  @spec normalize_issue_state(term()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  # Same nil-safety reasoning as `active_issue_state?/2` above.
  # Direct callers (routable_todo_issues, state_slots_available?,
  # effective_state_limit, running_issue_count_for_state) all feed
  # `issue.state` here without a binary guard; without this clause
  # any unlabeled issue crashes the orchestrator.
  def normalize_issue_state(_state_name), do: ""

  @spec state_slug(term()) :: String.t() | nil
  def state_slug(state_name) when is_binary(state_name) do
    state_name
    |> normalize_issue_state()
    |> String.replace(~r/[\s_]+/, "-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  def state_slug(_state_name), do: nil

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end
end
