defmodule Aiur.Orchestrator.FeatureSupplySnapshot do
  @moduledoc "Feature supply evidence from the dispatch snapshot; never fetches tracker data."

  alias Aiur.{Config, Issue, RunTelemetry}
  alias Aiur.GitHub.Tracker
  alias Aiur.Orchestrator.{DependencyGate, DispatchPolicy, Slots, State}
  alias Aiur.StartTrigger.ProgressStore

  @spec build(State.t(), [Issue.t()]) :: map()
  def build(state, issues) do
    active = DispatchPolicy.active_state_set()
    terminal = DispatchPolicy.terminal_state_set()
    features = issues |> Enum.uniq_by(& &1.id) |> Enum.filter(&feature?/1)
    decisions = Enum.map(features, &decide(&1, state, active, terminal))
    todos = Enum.filter(decisions, fn {issue, _} -> DispatchPolicy.normalize_issue_state(issue.state) == "todo" end)

    %{
      free: Slots.available_slots(state),
      feature_ready: Enum.count(decisions, &match?({_, :dispatch}, &1)),
      declines:
        todos
        |> Enum.flat_map(fn {_, decision} ->
          case decision do
            {:skip, reason} -> [to_string(reason)]
            :dispatch -> []
          end
        end)
        |> Enum.frequencies(),
      blockers: blockers(todos, terminal),
      non_feature_running: Enum.any?(state.running, fn {_, entry} -> State.active_running_entry?(entry) and not feature?(entry.issue) end)
    }
  end

  @spec feature?(Issue.t()) :: boolean()
  def feature?(issue), do: RunTelemetry.work_kind(issue.labels || [], issue.title) == "feature"

  defp decide(issue, state, active, terminal) do
    case cached(issue) do
      {:ok, hydrated} ->
        {hydrated, DispatchPolicy.dispatch_candidate_decision(hydrated, state, active, terminal, state.blocked_ticket_ids)}

      {:error, _unknown} ->
        # A cache miss cannot erase an independently known hold or prove readiness.
        case DispatchPolicy.dispatch_candidate_decision(issue, state, active, terminal, state.blocked_ticket_ids) do
          {:skip, reason} when reason != :dependency -> {issue, {:skip, reason}}
          _ -> {issue, {:skip, :dependency_unknown}}
        end
    end
  end

  defp cached(issue) do
    if Config.tracker_kind() == "github", do: Tracker.cached_blocked_by(issue), else: {:ok, issue}
  end

  defp blockers(todos, terminal) do
    todos
    |> Enum.flat_map(fn
      {_, {:skip, :dependency_unknown}} -> []
      {issue, _} -> elem(DependencyGate.hold_details(issue, terminal), 0) |> Enum.uniq_by(& &1[:id])
    end)
    |> Enum.group_by(& &1[:id])
    |> Enum.map(fn {id, rows} ->
      blocker = hd(rows)
      progress = ProgressStore.lookup(id) || %{}

      %{
        id: id,
        identifier: blocker[:identifier] || id,
        state: blocker[:state] || "unknown",
        feature_tickets: length(rows),
        pr_number: progress[:pr_number],
        pr_state: pr_state(progress),
        pr_stage: progress[:stage]
      }
    end)
    |> Enum.sort_by(&{-&1.feature_tickets, &1.id})
    |> Enum.take(5)
  end

  defp pr_state(%{closed_unmerged?: true}), do: "closed"
  defp pr_state(%{stage: :pr_merged}), do: "merged"
  defp pr_state(%{stage: stage}) when stage in [:pr_opened, :pr_ci_green, :pr_approved], do: "open"
  defp pr_state(_), do: "unknown"
end
