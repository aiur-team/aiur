defmodule Aiur.CI.TransientNetworkFailure do
  @moduledoc "Recognizes explicit transient network errors in failed GitHub Actions job logs."
  alias Aiur.GitHub.CIRecovery

  @signatures [
    "failed to connect to github.com",
    "nxdomain",
    "failed_connect",
    "could not resolve host"
  ]

  @test_failure_markers [
    "** (mix) test failed",
    "test failed",
    "tests failed",
    "exunit",
    "assertion",
    "assertion with == failed",
    "assertion failed",
    "doctest failed"
  ]

  @spec match?(term()) :: boolean()
  def match?(log) when is_binary(log) do
    text = String.downcase(log)
    not Enum.any?(@test_failure_markers, &String.contains?(text, &1)) and Enum.any?(@signatures, &String.contains?(text, &1))
  end

  def match?(_), do: false

  @spec run_has_network_only_failed_jobs?(binary(), keyword()) :: boolean()
  def run_has_network_only_failed_jobs?(url, opts) when is_binary(url) do
    with [run_id] <- Regex.run(~r{/actions/runs/(\d+)(?:/|$)}, url, capture: :all_but_first),
         {:ok, jobs} <- CIRecovery.jobs(String.to_integer(run_id), opts),
         failed when failed != [] <- Enum.filter(jobs, &(&1["conclusion"] in ["failure", "timed_out", "startup_failure"])),
         {:ok, logs} <- Enum.reduce_while(failed, {:ok, []}, &read_job_log(&1, &2, opts)) do
      Enum.all?(logs, &match?/1)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  def run_has_network_only_failed_jobs?(_, _), do: false

  defp read_job_log(%{"id" => id}, {:ok, logs}, opts) when is_integer(id) do
    case Keyword.get(opts, :ci_job_log, &fetch_job_log/2).(id, opts) do
      {:ok, log} when is_binary(log) -> {:cont, {:ok, [log | logs]}}
      _ -> {:halt, {:error, :job_log_unavailable}}
    end
  end

  defp read_job_log(_, _acc, _opts), do: {:halt, {:error, :invalid_job}}

  defp fetch_job_log(id, opts) do
    case CIRecovery.read("/actions/jobs/#{id}/logs", opts) do
      {:ok, log} when is_binary(log) -> {:ok, log}
      {:error, _} = error -> error
      _ -> {:error, :invalid_actions_job_log}
    end
  end
end
