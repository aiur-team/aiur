defmodule Aiur.GitHub.OverrideRecovery do
  @moduledoc "Fresh branch evidence and verified retirement for Command recovery."

  alias Aiur.GitHub.{Access, Comments}

  @spec pull_request(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def pull_request(number, opts \\ []) do
    with {:ok, base, token} <- context(opts),
         {:ok, %{"state" => state, "merged" => merged} = pr} when state in ["open", "closed"] and is_boolean(merged) <- request(:get, "#{base}/pulls/#{number}", nil, token, opts),
         {:ok, exists?} <- branch_exists(pr, token, opts) do
      {:ok,
       %{
         number: number,
         state: if(pr["state"] == "open", do: :open, else: :closed),
         merged?: pr["merged"] == true,
         head_ref: get_in(pr, ["head", "ref"]),
         head_sha: get_in(pr, ["head", "sha"]),
         branch_exists?: exists?,
         merge_commit_sha: pr["merge_commit_sha"]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :override_pr_evidence_missing}
    end
  end

  @spec close(pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def close(number, successor, opts \\ []) do
    with {:ok, base, token} <- context(opts),
         :ok <- ensure_comment(number, successor, opts),
         {:ok, %{"state" => "closed"}} <- request(:patch, "#{base}/pulls/#{number}", %{"state" => "closed"}, token, opts),
         {:ok, %{"state" => "closed", "merged" => false}} <- request(:get, "#{base}/pulls/#{number}", nil, token, opts) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :superseded_pr_not_closed}
    end
  end

  defp ensure_comment(number, successor, opts) do
    body = "superseded by ##{successor}"
    read = Keyword.get(opts, :comments, &Comments.fetch_classified_issue_comments/2)
    write = Keyword.get(opts, :comment, &Comments.create_comment/3)
    request = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
    opts = Keyword.put(opts, :request_fun, fn req -> request.(Map.put(req, :caller, "command_override_supersede")) end)

    with {:ok, comments} <- read.(to_string(number), opts) do
      if Enum.any?(comments, &((Map.get(&1, :body, Map.get(&1, "body", "")) || "") |> String.split("\n", parts: 2) |> List.first() == body)),
        do: :ok,
        else: write.(to_string(number), body, Keyword.put(opts, :caller, "command_override_supersede"))
    end
  end

  defp branch_exists(%{"state" => "closed"}, _token, _opts), do: {:ok, false}

  defp branch_exists(%{"head" => %{"repo" => %{"url" => url}, "ref" => ref}}, token, opts) when is_binary(ref) do
    case request(:get, "#{url}/git/ref/heads/#{URI.encode(ref, &URI.char_unreserved?/1)}", nil, token, opts) do
      {:ok, _} -> {:ok, true}
      {:error, {:github, :http, %{status: 404}}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  defp branch_exists(_, _token, _opts), do: {:error, :override_branch_evidence_missing}

  defp context(opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(), {:ok, token} <- Access.require_token(opts), do: {:ok, "#{Access.base_url()}/repos/#{owner}/#{repo}", token}
  end

  defp request(method, url, body, token, opts) do
    fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)

    case fun.(%{method: method, url: url, body: body, token: token, caller: "command_override_recovery"}) do
      {:ok, %{status: status, body: response}} when status in [200, 201] -> {:ok, response}
      {:ok, response} -> {:error, Access.github_status_error(response)}
      {:error, reason} -> {:error, Access.classify_error({:error, reason})}
    end
  end
end
