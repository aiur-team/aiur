defmodule Aiur.LandingWatch.MergeFailureOptions do
  @moduledoc false

  alias Aiur.GitHub.Client
  alias Aiur.LandingWatch.WorkflowTimeouts

  @spec build(map(), [integer()], [map()], keyword(), function()) :: keyword()
  def build(run, prs, jobs, opts, default_job_log) do
    opts
    |> add_changed_paths(prs)
    |> add_failure_signatures()
    |> add_timeout_minutes(run, jobs)
    |> Keyword.put(:job_log_fun, Keyword.get(opts, :job_log_fun, default_job_log))
  end

  defp add_changed_paths(opts, prs) do
    paths_fun = Keyword.get(opts, :changed_paths_fun, &Client.fetch_pull_request_changed_paths/2)
    paths_by_pr = Enum.reduce(prs, %{}, &fetch_pr_paths(&1, &2, paths_fun, opts))
    unavailable = for {pr, :unavailable} <- paths_by_pr, do: pr

    opts
    |> Keyword.put(:changed_paths_by_pr, paths_by_pr)
    |> Keyword.put(:changed_paths_unavailable_prs, unavailable)
    |> Keyword.put(:changed_paths_fun, changed_paths_fun(paths_by_pr))
  end

  defp fetch_pr_paths(pr, acc, paths_fun, opts) do
    case paths_fun.(pr, opts) do
      {:ok, paths} when is_list(paths) -> Map.put(acc, pr, paths)
      _ -> Map.put(acc, pr, :unavailable)
    end
  end

  defp changed_paths_fun(paths_by_pr) do
    fn numbers, _options ->
      if Enum.any?(numbers, &(paths_by_pr[&1] == :unavailable)),
        do: {:error, :pull_request_changed_paths_unavailable},
        else: {:ok, Enum.flat_map(numbers, &Map.get(paths_by_pr, &1, []))}
    end
  end

  defp add_failure_signatures(opts) do
    main_paths = Keyword.get(opts, :recent_main_failure_paths, [])

    opts
    |> Keyword.put(:known_failure_patterns, Keyword.get(opts, :known_failure_patterns, []))
    |> Keyword.put(:failed_on_main_fun, fn path, _ ->
      is_binary(path) and path in main_paths
    end)
  end

  defp add_timeout_minutes(opts, run, jobs) do
    timeout_minutes =
      if Enum.any?(jobs, &(&1["conclusion"] == "cancelled")),
        do:
          Keyword.get(opts, :workflow_timeouts_fun, &WorkflowTimeouts.for_jobs/3).(
            run,
            jobs,
            opts
          ),
        else: %{}

    Keyword.put(opts, :timeout_minutes_by_job, timeout_minutes)
  end
end
