defmodule Aiur.GitHub.CIRecovery do
  @moduledoc "Exact-head GitHub operations for bounded CI recovery."
  alias Aiur.GitHub.{Errors, Transport}

  @spec observe(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(number, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, body} <-
           Transport.github_graphql(
             Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
             token,
             "query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid isDraft state reviewDecision autoMergeRequest{enabledAt} mergeQueueEntry{id}}}}",
             %{owner: owner, repo: repo, number: number},
             caller: "ci_recovery"
           ),
         %{} = pr <- get_in(body, ["data", "repository", "pullRequest"]) do
      {:ok, pr}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recovery_observation}
    end
  end

  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts), do: request(:get, path, nil, opts)

  @spec rerun(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def rerun(run, opts), do: request(:post, "/actions/runs/#{run}/rerun-failed-jobs", %{}, opts)

  @spec jobs(integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def jobs(run, opts) when is_integer(run) and run > 0 do
    with {:ok, body} <- read("/actions/runs/#{run}/jobs?per_page=100", opts),
         jobs when is_list(jobs) <- body["jobs"] do
      {:ok, jobs}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_actions_jobs_response}
    end
  end

  def jobs(_, _), do: {:error, :invalid_actions_run_id}

  @spec cancel(integer(), keyword()) :: :ok | {:error, term()}
  def cancel(run, opts) when is_integer(run) and run > 0 do
    case request(:post, "/actions/runs/#{run}/cancel", %{}, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def cancel(_, _), do: {:error, :invalid_actions_run_id}

  defp request(method, path, body, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      req = %{method: method, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}#{path}", token: token, caller: "ci_recovery"}
      req = if method == :get, do: req, else: Map.put(req, :body, body)

      case request.(req) do
        {:ok, %{status: status} = response} when status in [200, 201, 202] -> {:ok, Map.get(response, :body) || %{}}
        {:ok, response} -> {:error, Errors.github_status_error(response)}
        {:error, _} = error -> error
      end
    end
  end
end
