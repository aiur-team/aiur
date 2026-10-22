defmodule Aiur.LandingWatch.MergeGroupFailureEvidence do
  @moduledoc false

  alias Aiur.GitHub.{CIRecovery, Client, Errors, FailureEvidence, Transport}

  require Logger

  @page_limit 5

  @spec test_paths(binary()) :: [String.t()]
  def test_paths(log) when is_binary(log) do
    Regex.scan(
      ~r/^\s*\d+\)\s+test .+\([^)]+\)\r?\n\s+((?:src\/)?test\/[\w.\/-]+_test\.exs):\d+(?::\d+)?/m,
      log,
      capture: :all_but_first
    )
    |> List.flatten()
    |> Enum.map(&normalize_test_path/1)
    |> Enum.uniq()
  end

  @spec normalize_test_path(String.t()) :: String.t()
  def normalize_test_path("test/" <> _ = path), do: "src/" <> path
  def normalize_test_path(path), do: path

  @spec recent_main_paths(binary(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def recent_main_paths(base, opts) do
    case Keyword.get(opts, :recent_main_failure_paths_fun, &fetch_recent_main_failure_paths/2).(
           base,
           opts
         ) do
      {:ok, paths} when is_list(paths) -> {:ok, paths |> Enum.filter(&is_binary/1) |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_recent_main_evidence, other}}
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

  # GitHub redirects job logs to a text/plain blob, so the body arrives as a binary.
  @spec job_log(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def job_log(job, opts) do
    case job["id"] do
      id when is_integer(id) ->
        case CIRecovery.read("/actions/jobs/#{id}/logs", opts) do
          {:ok, log} when is_binary(log) -> {:ok, log}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_actions_job_log}
        end

      _ ->
        {:error, :missing_actions_job_id}
    end
  end

  defp extract_test_paths(log) do
    test_paths(log)
  end

  @spec known_patterns(keyword()) :: list()
  def known_patterns(opts) do
    case Keyword.fetch(opts, :known_failure_patterns) do
      {:ok, patterns} ->
        known_flaky_patterns(opts) ++ patterns

      :error ->
        case Keyword.get(opts, :known_failure_patterns_fun, fn ->
               FailureEvidence.flake_issues(opts)
             end).() do
          {:ok, issues} when is_list(issues) ->
            known_flaky_patterns(opts) ++ Enum.flat_map(issues, &failure_issue_patterns(&1, opts))

          _ ->
            []
        end
    end
  end

  defp known_flaky_patterns(opts) do
    path = Keyword.get(opts, :known_flaky_tests_path, ".github/known-flaky-tests.txt")
    path = if Path.type(path) == :absolute, do: path, else: Path.join(repository_root(opts), path)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split(~r/[\r\n]+/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.flat_map(&known_flaky_signatures/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("known flaky test list unavailable path=#{path} reason=#{inspect(reason)}")
        []
    end
  end

  defp repository_root(opts) do
    Keyword.get(opts, :repo_root, Aiur.Codeowners.repo_root())
  end

  defp known_flaky_signatures(line) do
    case String.split(line, " :: ", parts: 2) do
      [module, name] ->
        name = String.replace_prefix(name, "test ", "")
        ["test #{name} (#{module})", "#{name} (#{module})"]

      _ ->
        [line]
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
