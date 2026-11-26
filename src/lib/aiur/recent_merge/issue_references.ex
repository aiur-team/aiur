defmodule Aiur.RecentMerge.IssueReferences do
  @moduledoc "In-memory derived references, keyed by the exact source fields."

  alias Aiur.RecentMerge.ClosingReferences

  @type identifiers :: {[String.t()], [String.t()]}

  @spec prepare(Aiur.RecentMerge.t()) :: Aiur.RecentMerge.t()
  def prepare(merge), do: %{merge | issue_references: {key(merge), get(merge)}}

  @spec get(Aiur.RecentMerge.t()) :: identifiers()
  def get(merge) do
    source = key(merge)

    case merge.issue_references do
      {^source, identifiers} -> identifiers
      _ -> parse(merge)
    end
  end

  defp key(merge), do: {merge.repository, merge.summary, merge.commit_messages}

  defp parse(merge) do
    [merge.summary | merge.commit_messages]
    |> Enum.map(&ClosingReferences.parse(&1, merge.repository))
    |> Enum.reduce({[], []}, fn {closing, linked}, {all_closing, all_linked} ->
      {Enum.uniq(all_closing ++ closing), Enum.uniq(all_linked ++ linked)}
    end)
  end
end
