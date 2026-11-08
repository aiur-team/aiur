defmodule Aiur.Orchestrator.CiLifecycle.Outcome do
  @moduledoc """
  Turns a CI poll result into the pass, failure, or stale-wait transition.
  """

  alias Aiur.Orchestrator.CiLifecycle.Outcome.Apply

  defdelegate recover_ci_poll_result(state, issue, result, opts), to: Apply
  defdelegate route_conflicting_pr(state, issue, result, opts), to: Apply
end
