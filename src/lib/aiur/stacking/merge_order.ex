defmodule Aiur.Stacking.MergeOrder do
  @moduledoc "Pure verdict on whether a merged PR landed before its blockers."

  @type containment :: :contained | :not_contained | :unknown

  @doc """
  `blockers` are `StackBaseEvidence.blocker_facts/1` entries. `contained` answers whether a
  merged blocker's merge commit is in the merged PR's head. Blockers whose PR is open or closed
  unmerged, or merged but not contained, are violations; blockers with no delivered PR facts or an
  unreadable containment are unverified. A violation wins over an unverified blocker.
  """
  @spec verdict([map()], (String.t() -> containment())) :: :ok | {:violation, [String.t()]} | {:unverified, [String.t()]}
  def verdict(blockers, contained) when is_list(blockers) and is_function(contained, 1) do
    classes = Enum.map(blockers, &{&1.id, classify(&1, contained)})
    ids = fn kind -> for {id, ^kind} <- classes, do: id end

    cond do
      ids.(:violation) != [] -> {:violation, ids.(:violation)}
      ids.(:unverified) != [] -> {:unverified, ids.(:unverified)}
      true -> :ok
    end
  end

  defp classify(%{pr: %{merged?: true, merge_commit_sha: sha}}, contained) when is_binary(sha) and sha != "" do
    case contained.(sha) do
      :contained -> :ok
      :not_contained -> :violation
      _ -> :unverified
    end
  end

  defp classify(%{pr: %{merged?: false}}, _contained), do: :violation
  defp classify(_blocker, _contained), do: :unverified
end
