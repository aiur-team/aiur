defmodule Aiur.LandingWatch.UnapprovedRecovery do
  @moduledoc false

  alias Aiur.GitHub.Client
  alias Aiur.LandingWatch.{ConflictRouting, LocalRead, PrRerun, PrRerunClassifier}

  @spec process(map(), keyword()) :: :ok | {:error, term()}
  def process(%{draft?: true}, _opts), do: :ok
  def process(%{review_decision: "CHANGES_REQUESTED"}, _opts), do: :ok
  def process(%{raw: %{"isDraft" => true}}, _opts), do: :ok
  def process(%{raw: %{"reviewDecision" => "CHANGES_REQUESTED"}}, _opts), do: :ok

  def process(observation, opts) do
    with {red_since, recovered_at} = window when is_integer(red_since) and is_integer(recovered_at) <- Keyword.get(opts, :main_ci_recovery_window),
         false <- ConflictRouting.conflicting?(observation),
         {:ok, runs} <- Keyword.get(opts, :recovery_runs_fun, &recovery_runs/2).(observation, opts),
         in_window <- Enum.filter(runs, &recovery_run_in_window?(&1, window)),
         stale <- Enum.filter(in_window, &stale_merge_ref?(&1, opts)),
         true <- stale != [] do
      PrRerun.recover_main_ci(observation, stale, window, opts)
    else
      false -> :ok
      _ -> :ok
    end
  end

  defp stale_merge_ref?(run, opts) do
    Keyword.get(opts, :stale_merge_ref_fun, &PrRerunClassifier.stale_merge_ref?/2).(run, opts)
  end

  defp recovery_run_in_window?(run, {red_since, recovered_at}) do
    case DateTime.from_iso8601(run["started_at"] || "") do
      {:ok, started, _} ->
        timestamp = DateTime.to_unix(started, :millisecond)

        run["status"] == "completed" and run["conclusion"] in ["failure", "timed_out", "startup_failure"] and
          timestamp >= red_since and timestamp <= recovered_at

      _ ->
        false
    end
  end

  defp recovery_runs(%{head: head}, opts) do
    with {:ok, %{check_runs: runs}} <-
           LocalRead.run(Keyword.get(opts, :ci_status_fun, &Client.fetch_commit_ci_status/2), [head, opts], opts) do
      failed = Enum.filter(runs, &(&1["status"] == "completed" and &1["conclusion"] in ["failure", "timed_out", "startup_failure"]))
      Keyword.get(opts, :hydrate_failed_jobs_fun, &Aiur.LandingWatch.hydrate_failed_jobs/2).(failed, opts)
    end
  end
end
