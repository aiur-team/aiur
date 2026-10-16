defmodule Aiur.LandingWatch.MergeGroupFailureEvidence do
  @moduledoc false

  alias Aiur.GitHub.{CIRecovery, Client, Errors, FailureEvidence, Transport}

  require Logger

  @page_limit 5

  @spec recent_main_paths(binary(), keyword()) :: [String.t()]
  def recent_main_paths(base, opts) do
    case Keyword.get(opts, :recent_main_failure_paths_fun, &fetch_recent_main_failure_paths/2).(
           base,
           opts
         ) do
      {:ok, paths} when is_list(paths) -> paths |> Enum.filter(&is_binary/1) |> Enum.uniq()
      _ -> []
    end
  end

  defp fetch_recent_main_failure_paths(base, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      since = Keyword.get(opts, :now_ms, System.system_time(:millisecond)) - 24 * 60 * 60_000
      created = DateTime.from_unix!(since, :millisecond) |> DateTime.to_iso8601()

      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <>
          URI.encode_query(%{
            branch: base,
            event: "push",
            status: "completed",
            created: ">=#{created}",
            per_page: 100
          })

      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      with {:ok, runs} <- read_pages(request, token, url, [], 0) do
        {:ok, Enum.flat_map(runs, &failed_main_run_paths(&1, opts)) |> Enum.uniq()}
      end
    end
  end

  defp failed_main_run_paths(%{"conclusion" => conclusion, "id" => id}, opts)
       when conclusion in ["failure", "timed_out", "startup_failure"] and is_integer(id) do
    case Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(id, opts) do
      {:ok, jobs} ->
        Enum.filter(jobs, &(&1["conclusion"] in ["failure", "timed_out", "startup_failure"]))
        |> Enum.flat_map(&main_failure_job_paths(&1, opts))

      _ ->
        []
    end
  end

  defp failed_main_run_paths(_, _opts), do: []

  defp main_failure_job_paths(job, opts) do
    case Keyword.get(opts, :job_log_fun, &job_log/2).(job, opts) do
      {:ok, log} when is_binary(log) -> extract_test_paths(log)
      _ -> []
    end
  end

  defp job_log(job, opts) do
    case job["id"] do
      id when is_integer(id) ->
        case CIRecovery.read("/actions/jobs/#{id}/logs", opts) do
          {:ok, %{"log" => log}} when is_binary(log) -> {:ok, log}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_actions_job_log}
        end

      _ ->
        {:error, :missing_actions_job_id}
    end
  end

  defp extract_test_paths(log) do
    case Regex.run(~r/(?:^|\s)([\w.\/-]+_test\.exs)(?::\d+)?/m, log, capture: :all_but_first) do
      [path] -> [path]
      _ -> []
    end
  end

  @spec known_patterns(keyword()) :: list()
  def known_patterns(opts) do
    case Keyword.fetch(opts, :known_failure_patterns) do
      {:ok, patterns} ->
        patterns

      :error ->
        case Keyword.get(opts, :known_failure_patterns_fun, fn ->
               FailureEvidence.flake_issues(opts)
             end).() do
          {:ok, issues} when is_list(issues) ->
            Enum.flat_map(issues, &failure_issue_patterns(&1, opts))

          _ ->
            []
        end
    end
  end

  defp failure_issue_patterns(issue, opts) do
    [issue["title"] || "", issue["body"] || "" | issue_comments(issue["number"], opts)]
    |> Enum.flat_map(&failure_signature_patterns/1)
  end

  defp failure_signature_patterns(text) when is_binary(text) do
    lines =
      text
      |> String.split(~r/[\r\n]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(byte_size(&1) < 5))

    paths = Regex.scan(~r/[\w.\/-]+_test\.exs/, text) |> List.flatten()

    test_names =
      case String.split(text, " :: ", parts: 2) do
        [_module, name] -> [String.replace_prefix(name, "test ", "")]
        _ -> []
      end

    (lines ++ paths ++ test_names) |> Enum.uniq()
  end

  defp failure_signature_patterns(_), do: []

  defp issue_comments(number, opts) when is_integer(number) do
    case Client.fetch_issue_comments_conditional(number, opts) do
      {:ok, comments, _etag} -> Enum.map(comments, &(&1["body"] || ""))
      _ -> []
    end
  end

  defp issue_comments(_number, _opts), do: []

  # GitHub lists runs newest first; past the cap keep what was read, as the run fetcher does (#4556).
  defp read_pages(_request, _token, _url, acc, @page_limit) do
    Logger.warning("Base-branch failure evidence truncated at #{@page_limit} pages (#{length(acc)} runs)")
    {:ok, acc}
  end

  defp read_pages(request, token, url, acc, page) do
    case request.(%{
           method: :get,
           url: url,
           token: token,
           caller: "landing_watch_merge_group_runs"
         }) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}} = response} when is_list(runs) ->
        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, acc ++ runs}
          next -> read_pages(request, token, next, acc ++ runs, page + 1)
        end

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end
end
