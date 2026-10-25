defmodule Aiur.Orchestrator.IssueSync.CapacityStarvation do
  @moduledoc """
  Preserves per-constraint starvation ages and alert lifecycles.
  """

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.Issue
  alias Aiur.Orchestrator.IssueSync.CapacityConstraints
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State

  @spec sync_todo_capacity_alert(State.t(), list()) :: State.t()
  def sync_todo_capacity_alert(%State{} = state, issues) when is_list(issues) do
    todo_issues = CapacityConstraints.routable_todo_issues(issues)

    over_capacity? = length(todo_issues) > Slots.max_concurrent_agent_limit(state)

    cond do
      over_capacity? and not state.todo_over_capacity_alert_active ->
        emit_todo_capacity_alert(state, todo_issues)
        %{state | todo_over_capacity_alert_active: true}

      not over_capacity? and state.todo_over_capacity_alert_active ->
        %{state | todo_over_capacity_alert_active: false}

      true ->
        state
    end
  end

  def sync_todo_capacity_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_capacity_starvation_alert(State.t(), list(), integer()) :: State.t()
  def sync_capacity_starvation_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    constraint_entries = CapacityConstraints.capacity_constraint_entries(state, issues)

    state
    |> capacity_starvation_context(issues, constraint_entries)
    |> sync_capacity_starvation_state(now_ms)
  end

  def sync_capacity_starvation_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_capacity_starvation_alert(State.t(), list()) :: State.t()
  def sync_capacity_starvation_alert(%State{} = state, issues) when is_list(issues),
    do: sync_capacity_starvation_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_capacity_starvation_alert(%State{} = state, _issues), do: state

  defp capacity_starvation_context(state, issues, constraint_entries) do
    %{
      state: state,
      configured: Slots.max_concurrent_agent_limit(state),
      effective: Slots.effective_concurrent_agent_limit(state),
      ready_count: state |> CapacityConstraints.ready_dispatch_issues(issues) |> length(),
      constraints: Enum.map(constraint_entries, & &1.detail),
      signature: CapacityConstraints.capacity_constraint_signature(constraint_entries)
    }
  end

  defp sync_capacity_starvation_state(%{ready_count: 0} = context, _now_ms),
    do: clear_capacity_starvation(context.state)

  defp sync_capacity_starvation_state(%{constraints: []} = context, _now_ms),
    do: clear_capacity_starvation(context.state)

  defp sync_capacity_starvation_state(context, now_ms) do
    starvation = Map.get(context.state, :capacity_starvation, %{})
    since_by_identity = capacity_starvation_ages(starvation, context.signature, now_ms)
    alerted_identities = active_alerted_identities(starvation, context.signature)
    due_identities = due_capacity_identities(since_by_identity, alerted_identities, now_ms)

    if due_identities == [] do
      put_capacity_starvation(context.state, since_by_identity, alerted_identities, context.signature)
    else
      emit_capacity_starvation_alert(context, since_by_identity, alerted_identities, due_identities)
    end
  end

  defp capacity_starvation_ages(starvation, identities, now_ms) do
    previous_ages = previous_capacity_starvation_ages(starvation, identities, now_ms)
    Map.new(identities, &{&1, Map.get(previous_ages, &1, now_ms)})
  end

  defp previous_capacity_starvation_ages(%{since_ms: ages}, _identities, _now_ms) when is_map(ages), do: ages

  defp previous_capacity_starvation_ages(%{since_ms: since_ms, signature: signature}, identities, _now_ms)
       when is_integer(since_ms) do
    Map.new(signature || identities, &{&1, since_ms})
  end

  defp previous_capacity_starvation_ages(_starvation, _identities, _now_ms), do: %{}

  defp active_alerted_identities(starvation, identities) do
    alerted =
      case Map.get(starvation, :alerted) do
        alerted when is_list(alerted) -> alerted
        _ -> legacy_alerted_identities(starvation, identities)
      end

    MapSet.intersection(MapSet.new(alerted), MapSet.new(identities))
  end

  defp legacy_alerted_identities(starvation, identities) do
    if Map.get(starvation, :alert_active) == true, do: starvation[:signature] || identities, else: []
  end

  defp due_capacity_identities(since_by_identity, alerted_identities, now_ms) do
    since_by_identity
    |> Enum.filter(fn {identity, since_ms} ->
      now_ms - since_ms >= CapacityConstraints.capacity_starvation_dwell_ms() and not MapSet.member?(alerted_identities, identity)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp emit_capacity_starvation_alert(context, since_by_identity, alerted_identities, due_identities) do
    next_alerted_identities = MapSet.union(alerted_identities, MapSet.new(due_identities))

    case Alerts.emit_system("system.dispatch.capacity_starved",
           reason: capacity_starvation_reason(context),
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        context.state
        |> put_capacity_starvation(since_by_identity, next_alerted_identities, context.signature)
        |> Map.put(:capacity_starvation_resolution_emitted, false)

      {:error, _reason} ->
        put_capacity_starvation(context.state, since_by_identity, alerted_identities, context.signature)
    end
  end

  defp capacity_starvation_reason(context) do
    "Ready tickets=#{context.ready_count}, live agents=#{State.active_running_count(context.state.running)}, " <>
      "effective cap=#{context.effective}, configured cap=#{context.configured}; " <>
      "dispatch constraints=#{Enum.join(context.constraints, "; ")}."
  end

  defp clear_capacity_starvation(%State{capacity_starvation_resolution_emitted: true} = state),
    do: put_cleared_capacity_starvation(state)

  defp clear_capacity_starvation(%State{} = state) do
    active? =
      Map.get(state.capacity_starvation, :alert_active, false) or
        AlertFeed.active_system_attention?("system.dispatch.capacity_starved")

    if active? do
      case Alerts.emit_system("system.dispatch.capacity_starved.resolved",
             reason: "Ready-work dispatch capacity recovered; fleet dispatch may resume.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok -> put_cleared_capacity_starvation(%{state | capacity_starvation_resolution_emitted: true})
        {:error, _reason} -> state
      end
    else
      put_cleared_capacity_starvation(%{state | capacity_starvation_resolution_emitted: true})
    end
  end

  defp put_cleared_capacity_starvation(state),
    do: %{state | capacity_starvation: %{since_ms: %{}, alert_active: false, signature: [], alerted: []}}

  defp put_capacity_starvation(state, since_by_identity, alerted_identities, signature) do
    %{
      state
      | capacity_starvation: %{
          since_ms: since_by_identity,
          alert_active: MapSet.size(alerted_identities) > 0,
          signature: signature,
          alerted: alerted_identities |> MapSet.to_list() |> Enum.sort()
        }
    }
  end

  defp emit_todo_capacity_alert(%State{} = state, todo_issues) when is_list(todo_issues) do
    case List.first(todo_issues) do
      %Issue{} = issue ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          issue: issue,
          worker_host: State.WorkerHost.running_worker_host(state, issue.id),
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )

      _ ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )
    end
  end
end
