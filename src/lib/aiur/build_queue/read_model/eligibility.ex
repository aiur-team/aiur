defmodule Aiur.BuildQueue.ReadModel.Eligibility do
  @moduledoc false

  @spec focus_startable?(map(), map(), map(), map(), map()) :: boolean()
  def focus_startable?(projection, members, observations, settings, state) do
    projection.state in [:ready, :promoted, :overridden] and projection.verdict == :ready and
      not stale_manual_override?(members[projection.issue_id], observations[projection.issue_id], settings) and
      not blocked_by_github?(Map.get(state, :native_blockers) || %{}, projection.issue_id)
  end

  @spec stale_manual_override?(map() | nil, map() | nil, map() | nil) :: boolean()
  def stale_manual_override?(
        %{override: :manual_promotion},
        %{labels: labels},
        %{tracker: %{github: %{label_prefix: prefix}}}
      )
      when is_list(labels) do
    "#{prefix}:todo" not in labels or
      Enum.any?(labels, &(&1 in ["#{prefix}:parked", "#{prefix}:paused"]))
  end

  def stale_manual_override?(_member, _observation, _settings), do: false

  defp blocked_by_github?(blocker_observations, id) do
    case Map.get(blocker_observations, id) do
      {:ok, blockers} -> Enum.any?(blockers, & &1.open?)
      {:unknown, _reason} -> true
      _ -> false
    end
  end
end
