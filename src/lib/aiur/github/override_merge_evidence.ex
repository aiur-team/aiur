defmodule Aiur.GitHub.OverrideMergeEvidence do
  @moduledoc "Reads the immutable merged PR head's commit date through governed transport."
  alias Aiur.GitHub.Access

  @spec read(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(%{head_sha: sha} = pr, opts \\ []) when is_binary(sha) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token(opts),
         request <- Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
         {:ok, %{status: 200, body: %{"sha" => ^sha, "commit" => %{"committer" => %{"date" => at}}}}} <-
           request.(%{method: :get, url: "#{Access.base_url()}/repos/#{owner}/#{repo}/commits/#{URI.encode(sha, &URI.char_unreserved?/1)}", token: token, caller: "command_override_merge_head"}),
         {:ok, committed_at, _} <- DateTime.from_iso8601(at) do
      {:ok, Map.put(pr, :committed_at, committed_at)}
    else
      {:error, _} = error -> error
      _ -> {:error, :merged_head_evidence_missing}
    end
  end
end
