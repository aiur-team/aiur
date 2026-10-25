defmodule Aiur.Orchestrator.DispatchPolicy.SpendCap do
  @moduledoc false

  alias Aiur.Issue
  alias Aiur.Orchestrator.SpendCap.Store

  @type decision :: :dispatch | {:skip, :spend_cap_exhausted | :spend_cap_unavailable}

  @spec decision(Issue.t()) :: decision()
  def decision(%Issue{} = issue), do: decision(issue, &Store.dispatch_admission/1)

  @doc false
  @spec decision(Issue.t(), function()) :: decision()
  def decision(%Issue{} = issue, admission) when is_function(admission, 1) do
    case Issue.tracker_identity(issue) do
      nil -> :dispatch
      identity -> normalize_admission(admission.(identity))
    end
  end

  defp normalize_admission(:allow), do: :dispatch
  defp normalize_admission({:skip, reason}), do: {:skip, reason}
end
