defmodule Aiur.MainWatch.GitHub do
  @moduledoc "Bounded base-branch Actions observations through the governed GitHub transport."
  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Evaluation
  alias Aiur.GitHub.{AppCredentials, AppToken, Config, Errors, PullRequests, Transport}

  @active_statuses ["queued", "in_progress", "waiting", "requested", "pending"]

  @spec poll(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def poll(branch, workflows, opts \\ []) do
    poll_once(branch, workflows, opts)
  end

  defp poll_once(branch, workflows, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, commit_window, commit_etag} <- commits(owner, repo, branch, token, opts),
         {commits, dates} = commit_window,
         {:ok, {runs, merge_groups}} <- runs(owner, repo, branch, commits, dates, workflows, token, opts),
         {:ok, observations} <- observations(commits, runs, workflows, opts) do
      {:ok,
       %{
         observations: observations,
         runs: runs,
         merge_groups: merge_groups,
         commits: commits,
         commit_dates: dates,
         commit_etag: commit_etag,
         actions_write: Keyword.get_lazy(opts, :actions_write, fn -> actions_write?(opts) end)
       }}
    end
  end

  @spec actions_write?(keyword()) :: boolean()
  def actions_write?(opts \\ []) do
    with true <- AppCredentials.configured?(),
         {:ok, key} <- AppCredentials.parse_private_key(),
         jwt = AppToken.app_jwt(key, AppCredentials.app_id()),
         url = "#{Transport.base_url()}/app/installations/#{AppCredentials.installation_id()}",
         request = %{
           method: :get,
           url: url,
           token: jwt,
           caller: "main_watch_permissions",
           credential_pinned?: true,
           credential_id: "github_app",
           credential_class: "github_app_jwt"
         },
         {:ok, %{status: 200, body: installation}} when is_map(installation) <- request_fun(opts).(request) do
      permissions = installation["permissions"]
      is_map(permissions) and permissions["actions"] == "write"
    else
      _ -> false
    end
  end

  @spec rerun(pos_integer(), keyword()) :: :ok | {:error, term()}
  def rerun(id, opts \\ [])

  def rerun(id, opts) when is_integer(id) and id > 0 do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request = %{method: :post, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs/#{id}/rerun", token: token, body: %{}, caller: "main_watch_canary"}

      case request_fun(opts).(request) do
        {:ok, %{status: 201}} -> :ok
        {:ok, response} -> {:error, Errors.github_status_error(response)}
        {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  def rerun(_, _), do: {:error, :invalid_actions_run_id}

  defp commits(owner, repo, branch, token, opts) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/commits?" <> URI.encode_query(%{sha: branch, per_page: 20})

    retained_commits = Keyword.get(opts, :commits)
    retained_dates = Keyword.get(opts, :commit_dates)
    etag = retained_etag(retained_commits, retained_dates, opts)

    request = github_request(token, "main_watch_commits", opts) |> Map.put(:url, url)
    request = if etag, do: Map.put(request, :etag, etag), else: request

    # Read only the first page: the window is the newest 20 commits, so its `rel="next"` link is expected.
    case request_fun(opts).(request) do
      {:ok, %{status: 200, body: commits} = response} when is_list(commits) ->
        commit_response({:ok, commits, response_etag(response) || etag}, retained_commits, retained_dates)

      {:ok, %{status: 304} = response} ->
        commit_response({:not_modified, response_etag(response) || etag}, retained_commits, retained_dates)

      {:ok, response} ->
        {:error, request_error(response, "main_watch_commits", opts)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  # A validator is only safe to send when its snapshot can answer a 304.
  defp retained_etag(commits, dates, opts) when is_list(commits) and is_list(dates) and length(commits) == length(dates) do
    case Keyword.get(opts, :commit_etag) do
      etag when is_binary(etag) and etag != "" -> etag
      _absent -> nil
    end
  end

  defp retained_etag(_commits, _dates, _opts), do: nil

  defp response_etag(response), do: Transport.header(Map.get(response, :headers, []), "etag")

  defp commit_response({:ok, commits, etag}, _retained_commits, _retained_dates) do
    if Enum.all?(commits, &(is_map(&1) and is_binary(&1["sha"]))) do
      window = Enum.take(commits, 20)
      dates = Enum.map(window, &timestamp(get_in(&1, ["commit", "committer", "date"])))
      {:ok, {Enum.map(window, & &1["sha"]), dates}, etag}
    else
      {:error, :invalid_main_commits}
    end
  end

  defp commit_response({:not_modified, etag}, commits, dates)
       when is_list(commits) and is_list(dates),
       do: {:ok, {commits, dates}, etag}

  defp commit_response({:not_modified, _etag}, _commits, _dates),
    do: {:error, :main_commits_not_modified_without_snapshot}

  defp runs(owner, repo, branch, commits, dates, workflows, token, opts) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <> URI.encode_query(%{branch: branch, event: "push", per_page: 100})

    queue_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <> URI.encode_query(%{event: "merge_group", per_page: 100})

    with {:ok, push_runs} <- runs_page(url, token, dates, opts),
         {:ok, queue_runs} <- runs_page(queue_url, token, dates, opts) do
      # Merge-group checks remain attached to landed SHAs but are not main health evidence.
      runs = Enum.filter(push_runs, &(&1["event"] == "push" and &1["head_branch"] == branch and (workflows == [] or &1["name"] in workflows)))
      # Active queue runs are reported for the sweep only; they never count as main coverage.
      merge_groups = Enum.filter(queue_runs, &(&1["event"] == "merge_group" and queue_run?(&1, branch, workflows) and &1["status"] in @active_statuses))
      {:ok, {runs |> Enum.filter(&watched?(&1, commits, branch, workflows)) |> sort_normalized(), sort_normalized(merge_groups)}}
    end
  end

  defp runs_page(url, token, dates, opts) do
    case request_fun(opts).(github_request(token, "main_watch_runs", opts) |> Map.put(:url, url)) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}} = response} when is_list(runs) ->
        incomplete = Transport.parse_next_page_url(Map.get(response, :headers, [])) && not window_covered?(runs, dates)
        if incomplete, do: {:error, :main_runs_incomplete}, else: {:ok, runs}

      {:ok, %{status: 200}} ->
        {:error, :invalid_main_runs}

      {:ok, response} ->
        {:error, request_error(response, "main_watch_runs", opts)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  # Merge-queue commits may have no push run; older pages are safe to omit only once their time window is covered.
  defp window_covered?(runs, dates) do
    created_at = Enum.map(runs, &timestamp(&1["created_at"]))

    dates != [] and created_at != [] and Enum.all?(dates ++ created_at, &is_integer/1) and Enum.min(created_at) <= Enum.min(dates)
  end

  defp watched?(run, commits, branch, workflows) do
    branch_event? = run["event"] == "push" and run["head_branch"] == branch

    run["head_sha"] in commits and branch_event? and (workflows == [] or run["name"] in workflows)
  end

  defp queue_run?(run, branch, workflows), do: queue_branch?(run, branch) and (workflows == [] or run["name"] in workflows)

  defp queue_branch?(run, branch),
    do: run["event"] == "merge_group" and is_binary(run["head_branch"]) and String.starts_with?(run["head_branch"], "gh-readonly-queue/#{branch}/")

  defp sort_normalized(runs), do: runs |> Enum.map(&normalize/1) |> Enum.sort_by(& &1.id, :desc)

  defp normalize(run),
    do: %{
      id: run["id"],
      sha: run["head_sha"],
      name: run["name"],
      suite_id: run["check_suite_id"],
      status: run["status"],
      conclusion: run["conclusion"],
      attempt: run["run_attempt"] || 1,
      event: run["event"],
      head_branch: run["head_branch"],
      started_at: timestamp(run["created_at"]),
      completed_at: timestamp(run["updated_at"]),
      url: run["html_url"]
    }

  defp observations(commits, runs, workflows, opts) do
    commits
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, &append_observation(&1, &2, runs, workflows, opts))
  end

  defp append_observation(sha, {:ok, acc}, runs, workflows, opts) do
    latest = newest_completed_workflow_runs(runs, sha, workflows)

    if latest != [] and (failed_workflow?(latest) or configured_workflows_complete?(runs, sha, workflows)) do
      case cached_observation(sha, latest, opts) do
        {:ok, observation} -> {:cont, {:ok, acc ++ [observation]}}
        error -> {:halt, error}
      end
    else
      {:cont, {:ok, acc}}
    end
  end

  defp newest_completed_workflow_runs(runs, sha, workflows) do
    runs
    |> Enum.filter(&(&1.sha == sha and &1.event == "push" and &1.status == "completed" and &1.conclusion not in [nil, "cancelled"] and (workflows == [] or &1.name in workflows)))
    |> Enum.sort_by(&{&1.completed_at || 0, &1.id}, :desc)
    |> Enum.uniq_by(& &1.name)
  end

  defp failed_workflow?(runs), do: Enum.any?(runs, &(&1.conclusion == "failure"))

  defp configured_workflows_complete?(runs, sha, workflows) do
    workflows == [] or
      Enum.all?(workflows, fn name ->
        Enum.any?(runs, &(&1.sha == sha and &1.name == name and &1.status == "completed" and &1.conclusion not in [nil, "cancelled"]))
      end)
  end

  defp cached_observation(sha, runs, opts) do
    fingerprint = Enum.map(runs, &{&1.name, &1.id, &1.attempt, &1.suite_id, &1.status, &1.conclusion, &1.started_at, &1.completed_at}) |> Enum.sort()
    cached = Enum.find(Keyword.get(opts, :history, []), &(&1.sha == sha and Map.get(&1, :run_fingerprint) == fingerprint))
    fields = [:sha, :started_at, :completed_at, :checks, :digest, :failed_workflow, :run_urls, :suspect_merges, :run_fingerprint]

    # Entries cached before non-blocking checks were excluded must be rebuilt.
    if is_map(cached) and Enum.all?(fields, &Map.has_key?(cached, &1)) and not Enum.any?(cached.checks, &Evaluation.non_blocking_name?(&1.name)) do
      {:ok, Map.take(cached, fields)}
    else
      with {:ok, observation} <- observation(sha, runs, opts), do: {:ok, Map.put(observation, :run_fingerprint, fingerprint)}
    end
  end

  defp observation(sha, runs, opts) do
    suites = Enum.map(runs, & &1.suite_id)

    with true <- Enum.all?(suites, &is_integer/1) and Enum.all?(runs, &is_integer(&1.completed_at)),
         {:ok, ci} <- PullRequests.fetch_commit_ci_status(sha, opts),
         checks = latest_checks(ci.check_runs, suites),
         ci = %{ci | check_runs: checks},
         true <- checks != [] and Enum.all?(checks, &(&1["status"] == "completed")),
         {:ok, digest} <- FailureDigest.build_from_ci(sha, ci, Keyword.put(opts, :check_suite_ids, suites)) do
      {:ok,
       %{
         sha: sha,
         started_at:
           runs
           |> Enum.filter(&(&1.conclusion in ["failure", "timed_out", "startup_failure"]))
           |> Enum.map(& &1.started_at)
           |> Enum.reject(&is_nil/1)
           |> Enum.min(fn -> nil end),
         completed_at: runs |> Enum.map(& &1.completed_at) |> Enum.max(),
         checks: Enum.map(checks, &%{name: &1["name"], conclusion: &1["conclusion"]}),
         digest: digest,
         failed_workflow: Enum.any?(runs, &(&1.conclusion == "failure")),
         run_urls: Enum.map(runs, & &1.url),
         suspect_merges: []
       }}
    else
      false -> {:error, :incomplete_main_checks}
      error -> error
    end
  end

  defp latest_checks(checks, suites) do
    checks
    |> Enum.filter(&(get_in(&1, ["check_suite", "id"]) in suites and get_in(&1, ["app", "slug"]) == "github-actions"))
    |> Enum.reject(&Evaluation.non_blocking_name?(&1["name"]))
    |> Enum.sort_by(& &1["id"], :desc)
    |> Enum.uniq_by(&{get_in(&1, ["check_suite", "id"]), &1["name"]})
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  defp request_fun(opts), do: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

  defp github_request(token, caller, _opts) do
    %{method: :get, token: token, caller: caller}
  end

  defp request_error(%{status: 401} = response, caller, opts) do
    credential = Map.get(response, :credential, credential_source(opts))
    {:github, :auth, %{status: 401, message: "Bad credentials", caller: caller, credential: credential}}
  end

  defp request_error(response, _caller, _opts), do: Errors.github_status_error(response)

  defp credential_source(opts) do
    case Keyword.get(opts, :credential_source, &Config.token_source/0).() do
      :github_app -> "github_app_installation"
      :env -> "github_token"
      :keyring -> "github_keyring"
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  catch
    _, _ -> "unknown"
  end
end
