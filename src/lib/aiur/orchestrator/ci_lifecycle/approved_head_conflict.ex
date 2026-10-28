defmodule Aiur.Orchestrator.CiLifecycle.ApprovedHeadConflict do
  @moduledoc false

  @spec primary_owns?(map()) :: boolean()
  def primary_owns?(result) do
    result[:review_decision] == "APPROVED" and
      result[:approved_review_head_sha] == result[:head_sha] and
      Aiur.Config.booted_instance_role() == "primary"
  end
end
