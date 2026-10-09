defmodule Aiur.GitHub.BlockerProgress do
  @moduledoc false
  alias Aiur.GitHub.{HumanReviewGate, PullRequests, ResourceStore, Transport}
  alias Aiur.StartTrigger.ProgressStore

  @spec approval(String.t(), ProgressStore.row() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def approval(id, row, opts \\ [])
  def approval(_id, %{closed_unmerged?: true}, _opts), do: {:ok, nil}

  def approval(_id, %{pr_number: number} = row, opts) when is_integer(number) do
    with {:ok, approved?} <- HumanReviewGate.approved_pull_request?(number, opts) do
      {:ok, %{pr_number: number, head_sha: row.head_sha, stage: if(approved?, do: :pr_approved, else: :pr_opened), source: :review}}
    end
  end

  def approval(id, _row, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, %{"number" => number, "draft" => false} = pr} <- PullRequests.fetch_open_pull_request_for_branch(id, opts),
         true <- same_repo?(pr, "#{owner}/#{repo}"),
         {:ok, approved?} <- HumanReviewGate.approved_pull_request?(number, opts) do
      {:ok, %{pr_number: number, head_sha: get_in(pr, ["head", "sha"]), stage: if(approved?, do: :pr_approved, else: :pr_opened), source: :review}}
    else
      {:ok, _absent_or_draft} -> {:ok, nil}
      false -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @spec identity(String.t()) :: map() | nil
  def identity(id) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, %{data: %{"number" => number, "state" => state, "draft" => false} = pr}} <- ResourceStore.fetch(ResourceStore.key(:branch_pull_request, owner, repo, id)),
         true <- is_integer(number) and number > 0 and state in ["open", "closed"],
         true <- same_repo?(pr, "#{owner}/#{repo}") do
      %{
        pr_number: number,
        head_sha: get_in(pr, ["head", "sha"]),
        stage: if(pr["merged"] == true, do: :pr_merged, else: :pr_opened),
        closed_unmerged?: pr["state"] == "closed" and pr["merged"] != true,
        source: :boot_identity
      }
    else
      _ -> nil
    end
  end

  defp same_repo?(pr, repo) do
    case get_in(pr, ["head", "repo", "full_name"]) do
      head_repo when is_binary(head_repo) -> String.downcase(head_repo) == String.downcase(repo)
      _ -> false
    end
  end
end
