defmodule Aiur.GitHub.PullRequests.Reviews do
  @moduledoc false

  alias Aiur.GitHub.ResourceStore

  @spec last_review_sha(String.t(), pos_integer()) :: String.t() | nil
  def last_review_sha(repo, pr_number) when is_binary(repo) and is_integer(pr_number) and pr_number > 0 do
    key = ResourceStore.key_for_repo(:pull_request_reviews, repo, pr_number)

    case ResourceStore.data(key) do
      reviews when is_list(reviews) ->
        reviews
        |> Enum.filter(&is_map/1)
        |> Enum.max_by(&Map.get(&1, "submitted_at", ""), fn -> nil end)
        |> then(&if(is_map(&1), do: Map.get(&1, "commit_id"), else: nil))
        |> case do
          sha when is_binary(sha) and sha != "" -> sha
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def last_review_sha(_repo, _pr_number), do: nil
end
