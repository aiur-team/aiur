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

  # Text endpoints such as job logs return a binary body; list endpoints such as commits return a list.
  @spec read(String.t(), keyword()) :: {:ok, map() | list() | binary()} | {:error, term()}
  def read(path, opts), do: request(:get, path, nil, opts)

  @spec rerun(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def rerun(run, opts), do: request(:post, "/actions/runs/#{run}/rerun-failed-jobs", %{}, opts)

  @doc "Merges the base into a PR branch for a fresh merge ref, only while its head is still `head`."
  @spec update_branch(integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_branch(number, head, opts), do: request(:put, "/pulls/#{number}/update-branch", %{expected_head_sha: head}, opts)

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

  @spec jobs_with_coverage(integer(), keyword()) :: {:ok, [map()], boolean()} | {:error, term()}
  def jobs_with_coverage(run, opts) when is_integer(run) and run > 0 do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs/#{run}/jobs?per_page=100&page=1"
      read_job_pages(request, token, url, [], 1, nil)
    end
  end

  def jobs_with_coverage(_, _), do: {:error, :invalid_actions_run_id}

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
      req = %{method: method, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}#{path}", token: token, caller: Keyword.get(opts, :caller, "ci_recovery")}
      req = if method == :get, do: req, else: Map.put(req, :body, body)

      case request.(req) do
        {:ok, %{status: status} = response} when status in [200, 201, 202] -> {:ok, Map.get(response, :body) || %{}}
        {:ok, response} -> {:error, Errors.github_status_error(response)}
        {:error, _} = error -> error
      end
    end
  end

  defp read_job_pages(_request, _token, _url, rows, page, _total) when page > 10, do: {:ok, rows, false}

  defp read_job_pages(request, token, url, rows, page, total) do
    response = request.(%{method: :get, url: url, token: token, caller: "ci_recovery"})
    handle_job_page(request, token, rows, page, total, response)
  end

  defp handle_job_page(request, token, rows, page, total, {:ok, %{status: 200, body: %{"jobs" => jobs} = body} = response}) when is_list(jobs) do
    all = rows ++ jobs
    expected = if Map.has_key?(body, "total_count"), do: max(total || 0, body["total_count"]), else: total
    next = Transport.parse_next_page_url(Map.get(response, :headers, []))

    cond do
      next == nil -> {:ok, all, is_integer(expected) and length(all) >= expected}
      page == 10 -> {:ok, all, false}
      true -> read_job_pages(request, token, next, all, page + 1, expected)
    end
  end

  defp handle_job_page(_request, _token, _rows, _page, _total, {:ok, response}), do: {:error, Errors.github_status_error(response)}
  defp handle_job_page(_request, _token, _rows, _page, _total, {:error, _} = error), do: error
end
