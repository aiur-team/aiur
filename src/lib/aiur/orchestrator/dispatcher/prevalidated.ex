defmodule Aiur.Orchestrator.Dispatcher.Prevalidated do
  @moduledoc """
  Dependency gate shared by every dispatch that does not come through the poll
  path's own validation (#7797). Resume, orphan-release and recovery callers hand
  over an issue read without `blocked_by`, so `Launch.do_dispatch_issue/5` runs
  `check/2` for them; the poll path passes `dependency_checked: true` because it
  already hydrated. Fails closed when the blockers cannot be read.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Launch
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State
  alias Aiur.Tracker

  @doc false
  @spec check(term(), keyword()) :: {:ok, term()} | {:error, :waiting_for_dependencies | :dependency_hydration_failed}
  def check(%Issue{} = issue, opts) do
    if Keyword.get(opts, :dependency_checked, false) do
      {:ok, issue}
    else
      hydrator = Keyword.get(opts, :blocked_by_hydrator, &Tracker.hydrate_blocked_by/1)

      issue |> hydrator.() |> gate()
    end
  end

  def check(issue, _opts), do: {:ok, issue}

  defp gate({:ok, %Issue{} = hydrated}) do
    if DispatchPolicy.issue_held_by_dependency?(hydrated, DispatchPolicy.terminal_state_set()),
      do: {:error, :waiting_for_dependencies},
      else: {:ok, hydrated}
  end

  defp gate(_unknown), do: {:error, :dependency_hydration_failed}

  @doc false
  @spec dispatch_prevalidated_issue(State.t(), Issue.t(), keyword()) ::
          {{:ok, :started} | {:error, term()}, State.t()}
  def dispatch_prevalidated_issue(%State{} = state, %Issue{} = issue, opts \\ []) do
    case check(issue, opts) do
      {:ok, hydrated} -> Launch.dispatch_prevalidated_issue(state, hydrated)
      {:error, reason} -> {{:error, reason}, state}
    end
  end
end
