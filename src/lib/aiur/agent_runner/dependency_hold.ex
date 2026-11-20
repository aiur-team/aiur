defmodule Aiur.AgentRunner.DependencyHold do
  @moduledoc """
  The dispatch dependency gate, applied to a worker that is still running.

  A fresh dispatch waits while any native `blocked_by` issue is open
  (`Aiur.Orchestrator.Dispatcher.Prevalidated`). A worker that stays alive
  between turns never passes that gate again, so a rework, a queued message or
  a continuation would start turns on a ticket that is waiting for another one.
  Before such a turn the runner asks `held?/2`; a held ticket leaves its input
  queued and ends the run, and normal dispatch takes it up once the blockers
  close.

  An unreadable blocker list does not hold: the worker is already running, and
  ending it on every GitHub budget hold would churn. The next turn reads again.
  """

  require Logger

  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy

  @doc """
  Whether `issue` must not start another turn: a `blocked_by` issue is open and
  the ticket's current state is one dispatch holds (todo or rework). The state
  is re-read only when a blocker is open, because the runner's copy can lag a
  rework someone else wrote.
  """
  @spec held?(Issue.t(), keyword()) :: boolean()
  def held?(%Issue{} = issue, opts) do
    hydrator = Keyword.get(opts, :blocked_by_hydrator, &Aiur.Tracker.hydrate_blocked_by/1)

    with {:ok, %Issue{} = hydrated} <- read(hydrator.(issue), issue),
         [_ | _] = blockers <- DispatchPolicy.holding_blockers(hydrated, DispatchPolicy.terminal_state_set()),
         {:ok, %Issue{} = current} <- read(current_state(hydrated, opts), issue),
         true <- DispatchPolicy.issue_held_by_dependency?(%{hydrated | state: current.state}, DispatchPolicy.terminal_state_set()) do
      Logger.info("aiur_dependency_hold identifier=#{issue.identifier} state=#{current.state} blockers=#{inspect(Enum.map(blockers, &blocker_id/1))}")
      true
    else
      _not_held -> false
    end
  end

  def held?(_issue, _opts), do: false

  defp current_state(%Issue{id: id} = issue, opts) when is_binary(id) do
    fetcher = Keyword.get(opts, :issue_state_fetcher, &Aiur.Tracker.fetch_issue_states_by_ids/1)

    case fetcher.([id]) do
      {:ok, [%Issue{} = current | _]} -> {:ok, current}
      {:ok, []} -> {:ok, issue}
      other -> other
    end
  end

  defp current_state(issue, _opts), do: {:ok, issue}

  defp read({:ok, %Issue{}} = ok, _issue), do: ok

  defp read(other, issue) do
    Logger.warning("aiur_dependency_hold identifier=#{issue.identifier} unreadable=#{inspect(other)}")
    :unreadable
  end

  defp blocker_id(blocker) when is_map(blocker), do: Map.get(blocker, :identifier) || Map.get(blocker, :id)
  defp blocker_id(blocker), do: blocker
end
