defmodule Aiur.Orchestrator.DispatchCandidates do
  @moduledoc "Orders known dependency holds after other candidates, without GitHub I/O."

  alias Aiur.{Config, Issue}
  alias Aiur.GitHub.Tracker
  alias Aiur.Orchestrator.DispatchPolicy

  @spec order([Issue.t()], MapSet.t()) :: [Issue.t()]
  def order(issues, terminal_states) do
    github? = Config.settings!().tracker.kind == "github"

    {held, ready} =
      issues
      |> DispatchPolicy.sort_issues_for_dispatch()
      |> Enum.split_with(&held?(&1, terminal_states, github?))

    ready ++ held
  end

  defp held?(issue, terminal_states, github?) do
    if github? and DispatchPolicy.normalize_issue_state(issue.state) == "todo" do
      case Tracker.cached_blocked_by(issue) do
        {:ok, hydrated} -> DispatchPolicy.todo_issue_held_by_dependency?(hydrated, terminal_states)
        {:error, _unknown} -> false
      end
    else
      DispatchPolicy.todo_issue_held_by_dependency?(issue, terminal_states)
    end
  end
end
