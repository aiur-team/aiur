defmodule Aiur.LandingWatch.HeldApproval do
  @moduledoc false

  @spec attention(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def attention(observation, issue, opts) do
    message = "Approved PR ##{observation.number} is held out of the merge queue; enable auto-merge or enqueue it when ready."

    Aiur.LandingWatch.emit_once(
      observation,
      "held-out-of-merge-queue",
      "ticket.#{issue}.agent.attention.approved_pr_not_armed_for_merge",
      message,
      "approved_pr_not_armed_for_merge",
      true,
      opts
    )
  end
end
