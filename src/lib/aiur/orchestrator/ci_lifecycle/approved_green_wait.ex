defmodule Aiur.Orchestrator.CiLifecycle.ApprovedGreenWait do
  @moduledoc false

  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Transition

  @spec eligible?(struct(), map()) :: boolean()
  def eligible?(issue, result) do
    CiLifecycle.ci_wait_state?(Transition.effective_ci_state(issue)) and
      result[:review_decision] == "APPROVED" and result[:reviewed_head?] == true and
      result[:draft?] == false and is_binary(result[:head_sha])
  end
end
