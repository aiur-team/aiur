defmodule Aiur.PRLifecycle.PostAgentRouting do
  @moduledoc "Shared post-agent PR verdict routing."

  alias Aiur.CodeHost
  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.PRLifecycle.ReviewFindings

  @doc "Routes an open PR to rework, CI wait, or the caller's fallback state."
  @spec route(map(), String.t(), keyword()) :: String.t()
  def route(pr, fallback, opts \\ []) do
    number = Map.get(pr, "number") || Map.get(pr, :number)
    fetcher = Keyword.get(opts, :reviews_fetcher, &CodeHost.fetch_classified_pr_reviews/1)

    case if(is_integer(number), do: fetcher.(number), else: {:error, :missing_number}) do
      {:ok, reviews} when is_list(reviews) -> target(pr, reviews, fallback, opts)
      _ -> fallback
    end
  end

  @doc false
  @spec target(map(), [map()], String.t(), keyword()) :: String.t()
  def target(pr, reviews, fallback, opts \\ []) do
    head = get_in(pr, ["head", "sha"])
    number = Map.get(pr, "number")

    cond do
      is_binary(head) and Enum.any?(blocking_reviews(reviews), &(&1["commit_id"] == head)) -> "rework"
      is_integer(number) and approved?(number, opts) -> "ci-wait"
      true -> fallback
    end
  end

  @doc false
  @spec blocking_reviews([map()]) :: [map()]
  def blocking_reviews(reviews) do
    reviews
    |> Enum.filter(&(&1["state"] in ~w(APPROVED CHANGES_REQUESTED DISMISSED) or ReviewFindings.blocking_body?(&1["body"])))
    |> Enum.group_by(&get_in(&1, ["user", "login"]))
    |> Enum.map(fn {_author, submissions} -> Enum.max_by(submissions, &{&1["submitted_at"], &1["id"]}) end)
    |> Enum.filter(fn review ->
      review[:authoritative] == true and
        (review["state"] == "CHANGES_REQUESTED" or
           (review["state"] == "COMMENTED" and ReviewFindings.blocking_body?(review["body"])))
    end)
  end

  @doc false
  @spec approved?(integer(), keyword()) :: boolean()
  def approved?(number, opts) do
    fetch = Keyword.get(opts, :pull_request_approval_fetcher) || (&default_approval_fetcher/1)
    classifier = Keyword.get(opts, :approval_carry_classifier) || (&GithubCIPoller.classify_approval_carry/4)

    case fetch.(number) do
      {:ok, {head, head}} when is_binary(head) -> true
      {:ok, {head, approved}} when is_binary(approved) -> classifier.(approved, head, number, []) == :carried
      _ -> false
    end
  end

  defp default_approval_fetcher(number),
    do: GitHubClient.pull_request_approval(number, caller: "approved_handoff")
end
