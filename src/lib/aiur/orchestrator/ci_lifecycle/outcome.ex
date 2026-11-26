defmodule Aiur.Orchestrator.CiLifecycle.Outcome do
  @moduledoc """
  Turns a CI poll result into the pass, failure, or stale-wait transition.
  """

  alias Aiur.Orchestrator.CiLifecycle.ExternalCi
  alias Aiur.Orchestrator.CiLifecycle.Outcome.Apply

  @spec recover_ci_poll_result(Aiur.Orchestrator.State.t(), Aiur.Issue.t(), map(), keyword()) :: Aiur.Orchestrator.State.t()
  def recover_ci_poll_result(state, issue, result, opts) do
    if Aiur.MergePolicy.external_ci?(),
      do: ExternalCi.apply_poll_result(state, issue, result, opts),
      else: Apply.recover_ci_poll_result(state, issue, result, opts)
  end

  defdelegate route_conflicting_pr(state, issue, result, opts), to: Apply
end
