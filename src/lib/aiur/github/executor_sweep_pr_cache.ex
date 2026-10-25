defmodule Aiur.GitHub.ExecutorSweepPRCache do
  @moduledoc "Normalizes and stores PR facts selected by the existing comment poll batch."

  alias Aiur.GitHub.PollSnapshots

  @spec capture(String.t(), term(), map()) :: :ok | :unchanged
  def capture(repo, ticket, pull_request) do
    PollSnapshots.put_executor_sweep_pr(repo, ticket, pull_request)
  end

  @spec normalize(map()) :: map()
  def normalize(pull_request) do
    %{
      "approved_head_sha" => review_sha(pull_request, "APPROVED"),
      "reviewed_head_sha" => review_sha(pull_request),
      "mergeable" => Map.get(pull_request, "mergeable"),
      "mergeQueueEntry" => Map.get(pull_request, "mergeQueueEntry"),
      "autoMergeRequest" => Map.get(pull_request, "autoMergeRequest"),
      "created_at" => Map.get(pull_request, "createdAt"),
      "updated_at" => Map.get(pull_request, "updatedAt"),
      "ready_for_review_at" => ready_for_review_at(pull_request)
    }
  end

  @doc false
  @spec head_committed_at(map()) :: String.t() | nil
  def head_committed_at(pull_request) do
    case get_in(pull_request, ["commits", "nodes"]) do
      [_ | _] = nodes -> nodes |> List.last() |> get_in(["commit", "committedDate"])
      _other -> nil
    end
  end

  defp review_sha(pull_request, state \\ nil) do
    pull_request
    |> get_in(["reviews", "nodes"])
    |> List.wrap()
    |> Enum.find(fn review ->
      is_map(review) and (is_nil(state) or Map.get(review, "state") == state) and is_binary(get_in(review, ["commit", "oid"]))
    end)
    |> case do
      %{"commit" => %{"oid" => sha}} -> sha
      _ -> nil
    end
  end

  defp ready_for_review_at(pull_request) do
    pull_request
    |> get_in(["timelineItems", "nodes"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "__typename") == "ReadyForReviewEvent"))
    |> Enum.max_by(&Map.get(&1, "createdAt", ""), fn -> nil end)
    |> case do
      %{"createdAt" => timestamp} -> timestamp
      _ -> nil
    end
  end
end
