defmodule Aiur.Orchestrator.Dispatcher.Prevalidated do
  @moduledoc """
  Dependency gate for operator-resume dispatch. Callers hand over an issue read
  without `blocked_by`, so the gate the poll path runs must run here too (#7797).
  Fails closed when the blockers cannot be read.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Launch
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State
  alias Aiur.Tracker

  @doc false
  @spec dispatch_prevalidated_issue(State.t(), Issue.t(), keyword()) ::
          {{:ok, :started} | {:error, term()}, State.t()}
  def dispatch_prevalidated_issue(%State{} = state, %Issue{} = issue, opts \\ []) do
    hydrator = Keyword.get(opts, :blocked_by_hydrator, &Tracker.hydrate_blocked_by/1)

    case hydrator.(issue) do
      {:ok, %Issue{} = hydrated} ->
        if DispatchPolicy.issue_held_by_dependency?(hydrated, DispatchPolicy.terminal_state_set()),
          do: {{:error, :waiting_for_dependencies}, state},
          else: Launch.dispatch_prevalidated_issue(state, hydrated)

      _unknown ->
        {{:error, :dependency_hydration_failed}, state}
    end
  end
end
