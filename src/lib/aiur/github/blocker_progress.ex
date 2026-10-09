defmodule Aiur.GitHub.BlockerProgress do
  @moduledoc false
  alias Aiur.GitHub.{HumanReviewGate, PullRequests, ResourceStore, Transport}
  alias Aiur.StartTrigger.ProgressStore
  alias Aiur.TicketBranch

  @spec approval(String.t(), ProgressStore.row() | nil) :: {:ok, map() | nil} | {:error, term()}
  def approval(_id, %{closed_unmerged?: true}), do: {:ok, nil}

  def approval(_id, %{pr_number: number} = row) when is_integer(number) do
    with {:ok, approved?} <- HumanReviewGate.approved_pull_request?(number) do
      {:ok, %{pr_number: number, head_sha: row.head_sha, stage: if(approved?, do: :pr_approved, else: :pr_opened), source: :review}}
    end
  end

  def approval(id, _row) do
    with {:ok, %{"number" => number, "draft" => false} = pr} <- PullRequests.fetch_open_pull_request_for_branch(id),
         {:ok, approved?} <- HumanReviewGate.approved_pull_request?(number) do
      {:ok, %{pr_number: number, head_sha: get_in(pr, ["head", "sha"]), stage: if(approved?, do: :pr_approved, else: :pr_opened), source: :review}}
    else
      {:ok, _absent_or_draft} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @spec ci(String.t(), map()) :: :ok
  def ci(id, %{decision: :passed, pr_number: number} = result) when is_integer(number) do
    ProgressStore.record(id, %{pr_number: number, stage: :pr_ci_green, head_sha: Map.get(result, :head_sha), source: :ci})
  end

  def ci(_id, _result), do: :ok

  @spec delivery(map(), String.t()) :: :ok
  def delivery(pr, repo) when is_map(pr) do
    id = TicketBranch.ticket_id(get_in(pr, ["head", "ref"]))
    attrs = %{pr_number: pr["number"], head_sha: get_in(pr, ["head", "sha"]), source: :webhook}

    cond do
      is_nil(id) or not is_integer(pr["number"]) or not same_repo?(pr, repo) -> :ok
      pr["merged"] == true -> ProgressStore.record(id, Map.put(attrs, :stage, :pr_merged))
      pr["state"] == "closed" -> ProgressStore.record(id, Map.put(attrs, :closed_unmerged?, true))
      pr["state"] == "open" and pr["draft"] == false -> ProgressStore.record(id, Map.put(attrs, :stage, :pr_opened))
      true -> :ok
    end
  end

  def delivery(_pr, _repo), do: :ok

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
