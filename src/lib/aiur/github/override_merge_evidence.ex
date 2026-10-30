defmodule Aiur.GitHub.OverrideMergeEvidence do
  @moduledoc "Checks whether an immutable merged PR head contains the recorded worker push."
  alias Aiur.GitHub.Access

  @spec read(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(pr, opts \\ [])

  def read(%{head_sha: sha, worker_head_sha: sha} = pr, _opts) when is_binary(sha),
    do: {:ok, Map.put(pr, :head_contains_worker_push, true)}

  def read(%{head_sha: head, worker_head_sha: worker} = pr, opts) when is_binary(head) and is_binary(worker) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token(opts),
         request <- Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
         comparison <- URI.encode(worker, &URI.char_unreserved?/1) <> "..." <> URI.encode(head, &URI.char_unreserved?/1),
         {:ok, %{status: 200, body: %{"base_commit" => %{"sha" => ^worker}, "merge_base_commit" => %{"sha" => ancestor}, "status" => status}}} <-
           request.(%{method: :get, url: "#{Access.base_url()}/repos/#{owner}/#{repo}/compare/#{comparison}?per_page=1", token: token, caller: "command_override_merge_head"}),
         true <- status in ["ahead", "identical", "behind", "diverged"] and is_binary(ancestor) do
      {:ok, Map.put(pr, :head_contains_worker_push, ancestor == worker and status in ["ahead", "identical"])}
    else
      {:error, _} = error -> error
      _ -> {:error, :merged_head_evidence_missing}
    end
  end

  def read(%{worker_head_sha: worker}, _opts) when is_binary(worker), do: {:error, :merged_head_evidence_missing}
  def read(pr, _opts), do: {:ok, Map.put(pr, :head_contains_worker_push, false)}
end
