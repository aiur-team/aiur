defmodule Aiur.LandingWatch.QuarantineNightlyResults do
  @moduledoc false

  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.CIRecovery
  alias Aiur.LandingWatch.QuarantineAnnotations

  @quarantine_job "quarantined tests (non-blocking)"
  @quarantine_step "Run quarantined tests"

  @spec fetch(keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch(opts) do
    case Keyword.get(opts, :nightly_quarantine_results_fun) do
      fun when is_function(fun, 1) -> fun.(opts)
      _ -> fetch_runs(opts)
    end
  end

  defp fetch_runs(opts) do
    case CIRecovery.read("/actions/runs?event=schedule&status=completed&per_page=20", opts) do
      {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
        runs
        |> Enum.filter(&(&1["name"] == "ci" and &1["head_branch"] == TrackerSettings.base_branch(opts) and is_integer(&1["id"])))
        |> Enum.reduce_while({:ok, []}, &append_result(&1, &2, opts))

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_quarantine_nightly_runs}
    end
  end

  defp append_result(run, {:ok, acc}, opts) do
    case run_result(run, opts) do
      {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp run_result(run, opts) do
    with {:ok, jobs} <- CIRecovery.jobs(run["id"], opts),
         {:ok, job} <- quarantine_job(jobs),
         {:ok, result} <- job_result(job, opts) do
      {:ok, Map.put(result, :run_id, run["id"])}
    end
  end

  defp quarantine_job(jobs) do
    case Enum.find(jobs, &(&1["name"] == @quarantine_job)) do
      nil -> {:ok, %{"conclusion" => "unknown", "steps" => []}}
      job -> {:ok, job}
    end
  end

  defp job_result(job, opts) do
    step = Enum.find(job["steps"] || [], &(&1["name"] == @quarantine_step))

    case step_status(job, step) do
      :success -> {:ok, %{fallback: :success, failures: %{}}}
      :failure -> annotated_failures(job, opts)
      :unknown -> {:ok, %{fallback: :unknown, failures: %{}}}
    end
  end

  defp step_status(_job, %{"outcome" => "success"}), do: :success
  defp step_status(_job, %{"conclusion" => "success"}), do: :success
  defp step_status(_job, %{"outcome" => "failure"}), do: :failure
  defp step_status(_job, %{"conclusion" => "failure"}), do: :failure
  defp step_status(%{"conclusion" => "success"}, nil), do: :success
  defp step_status(%{"conclusion" => conclusion}, _step) when conclusion in ["failure", "timed_out", "cancelled"], do: :failure
  defp step_status(_job, _step), do: :unknown

  defp annotated_failures(job, opts) do
    case QuarantineAnnotations.from_checks([{check_run_id(job), job["name"] || @quarantine_job}], opts) do
      {:ok, found} when found.tests != [] ->
        failures = Map.new(found.tests, &{&1.module <> " :: " <> &1.name, :failure})
        {:ok, %{fallback: :success, failures: failures}}

      {:ok, _found} ->
        {:ok, %{fallback: :unknown, failures: %{}}}

      {:error, _} = error ->
        error
    end
  end

  defp check_run_id(%{"check_run_id" => id}) when is_integer(id), do: id

  defp check_run_id(%{"check_run_url" => url}) when is_binary(url) do
    case Regex.run(~r{/check-runs/(\d+)\z}, url, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp check_run_id(_job), do: nil
end
