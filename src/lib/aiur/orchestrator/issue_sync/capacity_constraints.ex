defmodule Aiur.Orchestrator.IssueSync.CapacityConstraints do
  @moduledoc """
  Builds dispatch-ready issue sets and capacity constraint identities.
  """

  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State

  # The capacity-starvation dwell is data (#2447): `agent.capacity_starvation_
  # alert_after_seconds`, so the below-target ramp (which clears itself within
  # the bound) is filtered without hard-coding the threshold in this branch.
  @doc false
  @spec capacity_starvation_dwell_ms() :: non_neg_integer()
  def capacity_starvation_dwell_ms, do: Config.capacity_starvation_alert_after_seconds() * 1_000

  @doc false
  @spec routable_todo_issues(list()) :: [Issue.t()]
  def routable_todo_issues(issues) when is_list(issues) do
    issues
    |> Enum.filter(fn
      %Issue{} = issue ->
        DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
          not Issue.paused?(issue) and
          not Issue.parked?(issue) and
          DispatchPolicy.issue_routable_to_worker?(issue) and
          !DispatchPolicy.issue_held_by_dependency?(issue, DispatchPolicy.terminal_state_set())

      _ ->
        false
    end)
    |> DispatchPolicy.sort_issues_for_dispatch()
  end

  @doc false
  @spec ready_dispatch_issues(State.t(), [Issue.t()]) :: [Issue.t()]
  def ready_dispatch_issues(%State{} = state, issues) do
    state
    |> ready_dispatch_issues_without_decision_gate(issues)
    # A ticket waiting on an open operator Command is not capacity-blocked: no
    # amount of fleet capacity can start it. Counting it as ready makes a
    # decision-blocked fleet look capacity-starved (#2447). Dispatch already
    # skips these via `dispatch_state_decision`; keep the alert's "ready" set
    # aligned with what dispatch can actually admit. Fail-closed on
    # `:unavailable` (an unreadable DecisionStore) so an outage never reads as
    # capacity starvation — the outage raises its own alert instead (#2453).
    |> Enum.filter(&(!DispatchPolicy.blocked_on_decision?(&1, state.blocked_ticket_ids)))
  end

  # The ready set shared by the capacity-starvation alerts, WITHOUT the open
  # blocking-Command gate. The DecisionStore-outage alert
  # (`sync_decision_store_unavailable_alert/3`) reads this directly so queued
  # dispatchable work stays visible while `blocked_ticket_ids` is `:unavailable`
  # — `blocked_on_decision?/2` fails closed there, filtering every ticket out of
  # `ready_dispatch_issues/2` and silently suppressing capacity-starvation
  # alerting for the duration of the outage (#2453).
  @doc false
  @spec ready_dispatch_issues_without_decision_gate(State.t(), [Issue.t()]) :: [Issue.t()]
  def ready_dispatch_issues_without_decision_gate(%State{} = state, issues) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()

    issues
    |> Enum.filter(fn issue ->
      DispatchPolicy.candidate_issue?(issue, active_states, terminal_states) and
        !DispatchPolicy.issue_held_by_dependency?(issue, terminal_states)
    end)
    |> Enum.reject(fn issue ->
      Map.has_key?(state.running, issue.id) or MapSet.member?(state.claimed, issue.id) or
        Map.has_key?(state.retry_attempts, issue.id) or dependency_declined?(state, issue)
    end)
  end

  # The `blocked_by` filter above only sees what the poll snapshot carried, and
  # on GitHub that is nothing: blockers are hydrated from the Issue Dependencies
  # API at dispatch time, not at poll time. Dispatch performs the hydrated check
  # and records the ticket's decline as `:dependency`; without consulting that
  # record, every DAG-blocked ticket reads as capacity-ready work and a fleet
  # with all graph-ready tickets running wakes the Executor with a starvation
  # attention no added capacity could ever satisfy (#2592).
  #
  # Only the non-attention `:dependency` decline counts as expected DAG waiting.
  # `:dependency_hydration_failed` is an actionable failure — the blocker set is
  # unknown, not known-blocking — so a ticket held there stays ready work and
  # still alerts.
  defp dependency_declined?(%State{} = state, issue),
    do: Map.get(state.dispatch_declines, issue.id) in [:dependency, :optimistic_share, :queue_set_order]

  @doc false
  @spec capacity_constraint_entries(State.t(), [Issue.t()]) :: [map()]
  def capacity_constraint_entries(%State{} = state, issues) do
    state.dispatch_capacity_constraints
    |> Enum.flat_map(&dispatch_capacity_constraint_entry/1)
    |> Kernel.++(per_state_capacity_constraint_entries(state, issues))
    |> Kernel.++(budget_capacity_constraint_entries(state, issues))
    |> Enum.uniq_by(& &1.identity)
    |> Enum.sort_by(& &1.detail)
  end

  @doc false
  @spec capacity_constraint_signature([map()]) :: [String.t()]
  def capacity_constraint_signature(constraint_entries) do
    constraint_entries
    |> Enum.map(& &1.identity)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dispatch_capacity_constraint_entry(%{kind: kind} = constraint) do
    case render_capacity_constraint(constraint) do
      detail when is_binary(detail) -> [%{identity: dispatch_constraint_identity(kind), detail: detail}]
      nil -> []
    end
  end

  defp dispatch_capacity_constraint_entry(_constraint), do: []

  defp dispatch_constraint_identity(:build), do: "build"
  defp dispatch_constraint_identity(:cpu_pressure), do: "cpu-pressure"
  defp dispatch_constraint_identity(:fd), do: "fd"
  defp dispatch_constraint_identity(:load), do: "load"
  defp dispatch_constraint_identity(:load_envelope), do: "load-envelope"
  defp dispatch_constraint_identity(:memory), do: "memory"
  defp dispatch_constraint_identity(:provider), do: "provider"
  defp dispatch_constraint_identity(:run_queue), do: "run-queue"
  defp dispatch_constraint_identity(kind), do: "dispatch:#{kind}"

  defp render_capacity_constraint(%{kind: :build, detail: detail}), do: "prewarm build (#{detail})"

  defp render_capacity_constraint(%{kind: :cpu_pressure, detail: detail}),
    do: "CPU PSI gate (#{detail})"

  defp render_capacity_constraint(%{kind: :fd, detail: detail}), do: "FD gate (#{detail})"
  defp render_capacity_constraint(%{kind: :load, detail: detail}), do: "load gate (#{detail})"

  defp render_capacity_constraint(%{kind: :load_envelope, detail: detail}),
    do: "adaptive envelope limit (#{detail})"

  defp render_capacity_constraint(%{kind: :memory, detail: detail}), do: "memory gate (#{detail})"

  defp render_capacity_constraint(%{kind: :provider, detail: detail}),
    do: "provider gate (#{detail})"

  defp render_capacity_constraint(%{kind: :run_queue, detail: detail}),
    do: "run-queue gate (#{detail})"

  defp render_capacity_constraint(_constraint), do: nil

  defp per_state_capacity_constraint_entries(%State{} = state, issues) do
    configured_limits = Config.settings!().agent.max_concurrent_agents_by_state || %{}

    ready_dispatch_issues(state, issues)
    |> Enum.map(&DispatchPolicy.normalize_issue_state(&1.state))
    |> Enum.uniq()
    |> Enum.flat_map(&per_state_capacity_constraint_entry(state, configured_limits, &1))
  end

  defp per_state_capacity_constraint_entry(state, configured_limits, issue_state) do
    with {:ok, limit} <- Map.fetch(configured_limits, issue_state),
         used <- DispatchPolicy.running_issue_count_for_state(state.running, issue_state),
         true <- used >= limit do
      [%{identity: "per-state:#{issue_state}", detail: "per-state limit (#{issue_state}=#{used}/#{limit})"}]
    else
      _ -> []
    end
  end

  defp budget_capacity_constraint_entries(%State{} = state, issues) do
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget]) || %{}

    ready_dispatch_issues(state, issues)
    |> Enum.flat_map(&budget_capacity_constraint_entry(&1.id, Map.get(budget, &1.id, %{})))
  end

  defp budget_capacity_constraint_entry(issue_id, %{tripped: :lifetime} = entry) do
    [%{identity: "budget:lifetime:#{issue_id}", detail: "budget latch (lifetime=#{Map.get(entry, :lifetime, 0)})"}]
  end

  defp budget_capacity_constraint_entry(issue_id, %{tripped: :window} = entry) do
    case budget_window_remaining_ms(entry, System.monotonic_time(:millisecond)) do
      remaining_ms when remaining_ms > 0 ->
        [%{identity: "budget:window:#{issue_id}", detail: "budget circuit (window, clears #{format_remaining_duration(remaining_ms)})"}]

      _ ->
        []
    end
  end

  defp budget_capacity_constraint_entry(_issue_id, _entry), do: []

  defp budget_window_remaining_ms(entry, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000
    max(0, Map.get(entry, :window_start_ms, now_ms) + window_ms - now_ms)
  end

  defp format_remaining_duration(milliseconds) when milliseconds < 60_000, do: "in <1m"
  defp format_remaining_duration(milliseconds), do: "in ~#{div(milliseconds + 59_999, 60_000)}m"
end
