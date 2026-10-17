defmodule Aiur.LandingWatch.MergeFailureClassifier do
  @moduledoc "Classifies failed merge-group runs from recorded Actions job logs."

  @type classification :: :infra | :known_non_pr | :inherited | :pr_caused

  @spec classify(map(), [map()], [map()], keyword()) :: {:ok, {classification(), map() | nil}} | {:error, term()}
  def classify(run, jobs, observations, opts \\ []) do
    log_fun = Keyword.get(opts, :job_log_fun, fn _job, _opts -> {:ok, ""} end)
    failed_jobs = Enum.filter(jobs, &(&1["conclusion"] in ["failure", "cancelled", "timed_out", "startup_failure"]))

    case logs_for_jobs(failed_jobs, log_fun, opts) do
      {:ok, evidence} -> {:ok, {classification(evidence, run, observations, opts), List.first(evidence)}}
      {:error, _} = error -> error
    end
  end

  defp classification(evidence, run, observations, opts) do
    cond do
      Enum.any?(evidence, &infra_evidence?(&1, opts)) -> :infra
      Enum.any?(evidence, &inherited_evidence?/1) -> :inherited
      Enum.any?(evidence, &known_non_pr_evidence?(&1, run, observations, opts)) -> :known_non_pr
      true -> :pr_caused
    end
  end

  defp logs_for_jobs(jobs, log_fun, opts) do
    Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, acc} ->
      case log_fun.(job, opts) do
        {:ok, log} when is_binary(log) -> {:cont, {:ok, acc ++ [%{job: job, log: log}]}}
        {:error, reason} -> {:halt, {:error, {:job_log, job["id"], reason}}}
        _ -> {:halt, {:error, :invalid_job_log}}
      end
    end)
  end

  defp infra_evidence?(%{job: job, log: log}, opts) do
    conclusion = String.downcase(to_string(job["conclusion"] || ""))
    duration = job["run_duration_ms"] || duration_ms(job)
    timeout_minutes = job["timeout_minutes"] || get_in(opts, [:timeout_minutes_by_job, job["name"]])
    text = String.downcase(to_string(log))

    failed_at_start?(conclusion, duration) or runner_error?(text) or timeout_failure?(conclusion, duration, timeout_minutes, text)
  end

  defp failed_at_start?(conclusion, duration),
    do: conclusion in ["timed_out", "startup_failure"] or (conclusion == "failure" and duration == 0)

  defp runner_error?(text),
    do: String.contains?(text, "runner lost") or String.contains?(text, "runner error")

  defp timeout_failure?(conclusion, duration, minutes, text) do
    explicit_timeout_log?(text) or
      (conclusion == "cancelled" and timeout_elapsed?(duration, minutes, text))
  end

  defp timeout_elapsed?(duration, minutes, text) do
    String.contains?(String.downcase(text), "superseded") or
      (is_integer(duration) and is_integer(minutes) and minutes > 0 and duration >= minutes * 60_000)
  end

  defp explicit_timeout_log?(text) do
    Enum.any?(["exceeded the maximum execution time", "exceeded its 20m bound"], &String.contains?(text, &1))
  end

  defp inherited_evidence?(%{job: job, log: log}) do
    text = String.downcase(to_string(log))

    needs =
      case Jason.decode(job["needs_json"] || "{}") do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    failed_dependencies = Enum.filter(Map.values(needs), &(&1["result"] == "failure"))
    job["inherited_failure"] == true or String.contains?(text, "headgreen") or String.contains?(text, "failure in an earlier merge group") or (job["name"] == "ci gate" and failed_dependencies != [])
  end

  defp known_non_pr_evidence?(%{job: job, log: log}, run, _observations, opts) do
    text = to_string(log)
    paths_result = Keyword.get(opts, :changed_paths_fun, fn _pr, _opts -> {:ok, []} end).(run_prs(run), opts)
    failing_path = extract_path(text)
    failure_run = test_run?(text) and is_binary(failing_path)

    ticket_match = Enum.any?(Keyword.get(opts, :known_failure_patterns, []), &String.contains?(String.downcase(text), String.downcase(&1)))
    recent_main = Keyword.get(opts, :failed_on_main_fun, fn _path, _opts -> false end).(failing_path, opts)

    changed_paths = Keyword.get(opts, :changed_paths_by_pr, %{})

    file_touched_by_pr =
      Enum.any?(run_prs(run), fn pr ->
        case Map.get(changed_paths, pr, []) do
          paths when is_list(paths) -> failing_path in paths
          _ -> true
        end
      end)

    failure_run and (ticket_match or recent_main) and match?({:ok, _}, paths_result) and not file_touched_by_pr and
      job["conclusion"] == "failure"
  end

  defp test_run?(text), do: Enum.any?(["mix test", "test coverage partition", "failed test", "test failure"], &String.contains?(String.downcase(text), &1))

  defp extract_path(text) do
    case Regex.run(~r/(?:^|\s)([\w.\/-]+_test\.exs)(?::\d+)?/m, text, capture: :all_but_first) do
      [path] -> path
      _ -> nil
    end
  end

  defp run_prs(%{"head_branch" => branch}) when is_binary(branch) do
    Regex.scan(~r/pr-(\d+)-/, branch, capture: :all_but_first) |> List.flatten() |> Enum.map(&String.to_integer/1)
  end

  defp run_prs(_), do: []

  defp duration_ms(%{"started_at" => start, "completed_at" => finish}) when is_binary(start) and is_binary(finish) do
    case {DateTime.from_iso8601(start), DateTime.from_iso8601(finish)} do
      {{:ok, a, _}, {:ok, b, _}} -> DateTime.diff(b, a, :millisecond)
      _ -> nil
    end
  end

  defp duration_ms(_), do: nil
end
