defmodule Aiur.GitHub.CIPollBatchReadyReview do
  @moduledoc false

  @doc false
  @spec fields() :: String.t()
  def fields do
    """
    timelineItems(itemTypes: [REOPENED_EVENT, READY_FOR_REVIEW_EVENT], last: 100) { nodes { __typename ... on ReopenedEvent { createdAt } ... on ReadyForReviewEvent { createdAt } } }
    reviews(last: 100) { nodes { state commit { oid } } }
    """
  end

  @doc false
  @spec project(map()) :: map()
  def project(node) do
    %{
      ready_at_ms: ready_at_ms(node),
      reviewed_head?: reviewed_head?(node),
      approved_review_head_sha: approved_review_head_sha(node)
    }
  end

  defp ready_at_ms(node) do
    node
    |> get_in(["timelineItems", "nodes"])
    |> List.wrap()
    |> Enum.filter(&(Map.get(&1, "__typename") == "ReadyForReviewEvent"))
    |> Enum.map(&Map.get(&1, "createdAt"))
    |> Enum.filter(&is_binary/1)
    |> List.last()
    |> case do
      timestamp when is_binary(timestamp) -> timestamp_ms(timestamp) || timestamp_ms(Map.get(node, "createdAt"))
      _ -> timestamp_ms(Map.get(node, "createdAt"))
    end
  end

  defp reviewed_head?(%{"headRefOid" => head_sha} = node) when is_binary(head_sha) do
    node
    |> get_in(["reviews", "nodes"])
    |> List.wrap()
    |> Enum.any?(fn review -> get_in(review, ["commit", "oid"]) == head_sha end)
  end

  defp reviewed_head?(_node), do: false

  defp approved_review_head_sha(node) do
    with %{} = reviews <- Map.get(node, "reviews"),
         # `last:` nodes come oldest first, so the newest approval is the last match.
         review when is_map(review) <- (Map.get(reviews, "nodes") || []) |> Enum.filter(&(Map.get(&1, "state") == "APPROVED")) |> List.last(),
         %{} = commit <- Map.get(review, "commit"),
         sha when is_binary(sha) <- Map.get(commit, "oid") do
      sha
    else
      _ -> nil
    end
  end

  defp timestamp_ms(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_ms(_timestamp), do: nil
end
