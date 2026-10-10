defmodule Aiur.Orchestrator.DispatchCandidates do
  @moduledoc """
  Splits a pass's candidates by their cached dependency evidence, without GitHub I/O.

  A `todo` ticket whose cached evidence is current and names an open blocker is
  *held*: it cannot dispatch this pass, so it never enters the asynchronous
  validation chain. Validating ~200 such tickets one at a time kept ready work
  idle for minutes per pass (#4174).

  Every other candidate goes to the chain in priority order. A ticket whose
  evidence is too old to decide on, but last named an open blocker, goes after
  the rest: its re-read must not delay ready work.
  """

  alias Aiur.{Config, Issue}
  alias Aiur.GitHub.Tracker
  alias Aiur.Orchestrator.DispatchPolicy

  @doc "Returns `{chain, held}`. Each held issue carries its cached `blocked_by`."
  @spec partition([Issue.t()], MapSet.t()) :: {[Issue.t()], [Issue.t()]}
  def partition(issues, terminal_states) do
    github? = Config.settings!().tracker.kind == "github"
    classified = issues |> DispatchPolicy.sort_issues_for_dispatch() |> Enum.map(&classify(&1, terminal_states, github?))

    {pick(classified, :chain) ++ pick(classified, :last), pick(classified, :held)}
  end

  defp pick(classified, class), do: for({^class, issue} <- classified, do: issue)

  defp classify(issue, terminal_states, github?) do
    cond do
      github? and DispatchPolicy.normalize_issue_state(issue.state) == "todo" -> classify_cached(issue, terminal_states)
      # Other trackers carry blockers from the poll, so the chain declines them without I/O.
      open_blocker?(issue, terminal_states) -> {:last, issue}
      true -> {:chain, issue}
    end
  end

  defp classify_cached(issue, terminal_states) do
    case Tracker.cached_blocked_by(issue) do
      {:ok, hydrated} -> if open_blocker?(hydrated, terminal_states), do: {:held, hydrated}, else: {:chain, issue}
      {:error, _unknown} -> if last_known_hold?(issue, terminal_states), do: {:last, issue}, else: {:chain, issue}
    end
  end

  defp last_known_hold?(issue, terminal_states) do
    case Tracker.last_known_blocked_by(issue) do
      {:ok, hydrated} -> open_blocker?(hydrated, terminal_states)
      {:error, _none} -> false
    end
  end

  defp open_blocker?(issue, terminal_states), do: DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states)
end
