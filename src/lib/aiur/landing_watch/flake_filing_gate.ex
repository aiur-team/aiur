defmodule Aiur.LandingWatch.FlakeFilingGate do
  @moduledoc "Skips flake tickets for stale runs and for tests already changed on the base branch since the run (#4905)."

  require Logger

  alias Aiur.GitHub.CIRecovery

  @max_run_age_ms 12 * 60 * 60 * 1_000

  @spec decide(map(), map(), integer(), [map()], String.t(), keyword()) :: :file | {:skip, :stale_run | :test_changed_on_base}
  def decide(failure, run, run_at_ms, rows, base, opts) do
    cond do
      stale_without_newer_failure?(failure, run_at_ms, rows, opts) -> {:skip, :stale_run}
      test_changed_since_run?(failure, run, base, opts) -> {:skip, :test_changed_on_base}
      true -> :file
    end
  end

  defp stale_without_newer_failure?(failure, run_at_ms, rows, opts) do
    cutoff = Keyword.get(opts, :now_ms, System.system_time(:millisecond)) - Keyword.get(opts, :flake_max_run_age_ms, @max_run_age_ms)
    identity = "#{failure.module} :: #{failure.name}"

    run_at_ms < cutoff and
      not Enum.any?(rows, &(&1["identity"] == identity and is_integer(&1["at_ms"]) and &1["at_ms"] >= cutoff))
  end

  # The test changed after the run when the newest base commit touching it is not in the run's head.
  defp test_changed_since_run?(%{path: path}, %{"head_sha" => head} = run, base, opts) when is_binary(path) and is_binary(head) do
    query = URI.encode_query(%{sha: base, path: path, per_page: 1})
    opts = Keyword.put(opts, :caller, "landing_watch_flake_gate")

    with {:ok, [%{"sha" => latest} | _]} <- CIRecovery.read("/commits?" <> query, opts),
         {:ok, %{"status" => status}} <- CIRecovery.read("/compare/#{head}...#{latest}?per_page=1", opts) do
      status in ["ahead", "diverged"]
    else
      {:ok, []} ->
        false

      other ->
        # Fail open: a lookup error must not hide a real flake.
        Logger.warning("Flake filing gate could not compare #{path} for run #{run["id"]}: #{inspect(other)}")
        false
    end
  end

  defp test_changed_since_run?(_failure, _run, _base, _opts), do: false
end
