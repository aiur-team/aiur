defmodule Aiur.LandingWatch.RunnerDegradation do
  @moduledoc "Classifies merge-group runs whose failures indicate a degraded runner."

  alias Aiur.GitHub.CIRecovery
  alias Aiur.LandingWatch.MergeGroupFailureEvidence

  # Three independent test timeouts indicate runner contention; one slow test is inconclusive.
  @timeout_test_threshold 3
  # A 3x compile-step slowdown is large enough to distinguish infrastructure degradation from variance.
  @compile_slowdown_ratio 3
  # Five recent successful runs cap the median lookup at six Actions reads per job-name cache miss.
  @compile_history_runs 5

  @spec degraded?([map()], keyword()) :: boolean()
  def degraded?(jobs, opts) do
    failed = Enum.filter(jobs, &(&1["conclusion"] in ["failure", "timed_out", "startup_failure"]))
    logs = Enum.map(failed, &cached_log(&1, opts))

    Enum.any?(logs, &(timeout_count(&1) >= @timeout_test_threshold)) or
      Enum.any?(logs, &partition_bound?/1) or compile_slow?(jobs, opts)
  end

  defp cached_log(job, opts) do
    cache(opts, {:log, job["id"]}, fn ->
      log_opts = Keyword.put_new(opts, :caller, "landing_watch_runner_degradation")

      Keyword.get(opts, :job_log_fun, &MergeGroupFailureEvidence.job_log/2).(job, log_opts)
      |> unwrap_log()
    end)
  end

  defp unwrap_log({:ok, text}) when is_binary(text), do: text
  defp unwrap_log(_), do: ""

  defp timeout_count(text), do: length(Regex.scan(~r/\*\* \(ExUnit\.TimeoutError\)/, text))

  defp partition_bound?(text),
    do: Regex.match?(~r/(?:coverage )?partition \d+[^\n]*(?:exceeded its \d+m bound|killed at \d+m|time bound)/i, text)

  defp compile_slow?(jobs, opts) do
    Enum.any?(jobs, fn job ->
      compile_steps = Enum.filter(job["steps"] || [], &String.contains?(String.downcase(&1["name"] || ""), "compile"))

      Enum.any?(compile_steps, &slow_compile_step?(job, &1, opts))
    end)
  end

  defp slow_compile_step?(job, step, opts) do
    case step_duration_seconds(step) do
      duration when is_number(duration) ->
        median = compile_step_median(job["name"], step["name"], opts)
        is_number(median) and median > 0 and duration >= median * @compile_slowdown_ratio

      _ ->
        false
    end
  end

  defp compile_step_median(job_name, step_name, opts) do
    cache(opts, {:compile_median, job_name, step_name}, fn ->
      case Keyword.get(opts, :compile_median_fun, &recent_compile_median/3).(job_name, step_name, opts) do
        {:ok, median} when is_number(median) -> median
        _ -> nil
      end
    end)
  end

  defp recent_compile_median(job_name, step_name, opts) do
    base = Keyword.get(opts, :base_branch, "main")
    url = "/actions/runs?branch=#{URI.encode_www_form(base)}&event=push&status=completed&per_page=#{@compile_history_runs}"

    case CIRecovery.read(url, Keyword.put(opts, :caller, "landing_watch_runner_degradation")) do
      {:ok, %{"workflow_runs" => runs}} -> median_for_runs(runs, job_name, step_name, opts)
      _ -> {:error, :compile_history_unavailable}
    end
  end

  defp median_for_runs(runs, job_name, step_name, opts) do
    durations =
      runs
      |> Enum.filter(&(&1["conclusion"] == "success" and is_integer(&1["id"])))
      |> Enum.flat_map(&recent_job_steps(&1["id"], job_name, step_name, opts))
      |> Enum.sort()

    case durations do
      [] -> {:error, :compile_history_unavailable}
      values -> {:ok, Enum.at(values, div(length(values), 2))}
    end
  end

  defp recent_job_steps(run_id, job_name, step_name, opts) do
    case cache(opts, {:jobs, run_id}, fn -> CIRecovery.jobs(run_id, Keyword.put(opts, :caller, "landing_watch_runner_degradation")) end) do
      {:ok, jobs} ->
        jobs
        |> Enum.filter(&(&1["name"] == job_name))
        |> Enum.flat_map(fn job ->
          (job["steps"] || [])
          |> Enum.filter(&(&1["name"] == step_name and &1["conclusion"] == "success"))
          |> Enum.map(&step_duration_seconds/1)
          |> Enum.filter(&is_number/1)
        end)

      _ ->
        []
    end
  end

  defp step_duration_seconds(%{"started_at" => started, "completed_at" => completed}) do
    with {:ok, start, _} <- DateTime.from_iso8601(started),
         {:ok, finish, _} <- DateTime.from_iso8601(completed) do
      DateTime.diff(finish, start, :second)
    else
      _ -> nil
    end
  end

  defp step_duration_seconds(_), do: nil

  defp cache(opts, key, fun) do
    case Keyword.get(opts, :runner_degradation_cache) do
      pid when is_pid(pid) ->
        case Agent.get(pid, &Map.fetch(&1, key)) do
          {:ok, value} -> value
          :error -> cache_missing(pid, key, fun.())
        end

      _ ->
        fun.()
    end
  end

  defp cache_missing(pid, key, value) do
    Agent.update(pid, &Map.put(&1, key, value))
    value
  end
end
