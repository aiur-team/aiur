defmodule Aiur.LandingWatch.RunnerDegradation do
  @moduledoc "Classifies merge-group runs whose failures indicate a degraded runner."

  @timeout_markers ["ExUnit.TimeoutError", "timed out", "timeout after", "operation timed out"]

  @spec degraded?([map()], keyword()) :: boolean()
  def degraded?(jobs, opts) do
    failed_jobs = Enum.filter(jobs, &(&1["conclusion"] in ["failure", "timed_out", "startup_failure"]))
    logs = Enum.map(failed_jobs, &log(&1, opts))
    timeout_jobs = Enum.count(logs, &timeout_log?/1)

    timeout_jobs >= 2 or Enum.any?(logs, &partition_bound?/1) or
      compile_slow?(failed_jobs, opts)
  end

  defp log(job, opts) do
    case Keyword.get(opts, :job_log_fun, fn _job, _opts -> {:ok, ""} end).(job, opts) do
      {:ok, text} when is_binary(text) -> text
      _ -> ""
    end
  end

  defp timeout_log?(text), do: Enum.any?(@timeout_markers, &String.contains?(text, &1))
  defp partition_bound?(text), do: Regex.match?(~r/coverage partition \d+[^\n]*(?:20m|20 minutes|time bound)|partition[^\n]*(?:killed|time bound|timeout)/i, text)

  defp compile_slow?(jobs, opts) do
    case Keyword.get(opts, :compile_median_seconds) do
      median when is_number(median) and median > 0 ->
        Enum.any?(jobs, fn job ->
          name = String.downcase(job["name"] || "")
          duration = duration_seconds(job)
          String.contains?(name, "compile") and is_number(duration) and duration >= median * 3
        end)

      _ ->
        false
    end
  end

  defp duration_seconds(%{"started_at" => started, "completed_at" => completed}) do
    with {:ok, started, _} <- DateTime.from_iso8601(started),
         {:ok, completed, _} <- DateTime.from_iso8601(completed) do
      DateTime.diff(completed, started, :second)
    else
      _ -> nil
    end
  end

  defp duration_seconds(_job), do: nil
end
