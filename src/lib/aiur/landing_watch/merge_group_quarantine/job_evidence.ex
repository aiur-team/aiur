defmodule Aiur.LandingWatch.MergeGroupQuarantine.JobEvidence do
  @moduledoc false

  alias Aiur.GitHub.CIRecovery
  alias Aiur.LandingWatch.QuarantineAnnotations

  @spec load(pos_integer(), keyword()) :: {:ok, [map()], map(), boolean()} | {:error, term()}
  def load(run_id, opts) do
    with {:ok, jobs, jobs_complete?} <- jobs(run_id, opts),
         {:ok, found, annotations_complete?} <- QuarantineAnnotations.from_jobs_with_completeness(jobs, opts) do
      {:ok, jobs, found, jobs_complete? and annotations_complete?}
    end
  end

  defp jobs(run_id, opts) do
    cond do
      Keyword.has_key?(opts, :jobs_with_coverage_fun) -> opts[:jobs_with_coverage_fun].(run_id, opts)
      Keyword.has_key?(opts, :jobs_fun) -> legacy_jobs(run_id, opts)
      true -> CIRecovery.jobs_with_coverage(run_id, opts)
    end
  end

  defp legacy_jobs(run_id, opts) do
    case opts[:jobs_fun].(run_id, opts) do
      {:ok, jobs} -> {:ok, jobs, false}
      {:error, _} = error -> error
    end
  end
end
