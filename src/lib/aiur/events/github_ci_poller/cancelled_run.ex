defmodule Aiur.Events.GithubCIPoller.CancelledRun do
  @moduledoc """
  Shared recognition for workflow runs cancelled without a real upstream failure.

  An aggregate gate job (`if: always()` over the real jobs, such as aiur's
  `ci gate` or a repository's `required`) fails whenever its upstream jobs were
  cancelled. That failure says nothing about the code, so a run whose only
  failures are such gates is cancelled, not failed. A gate is the job named
  `ci gate`, or a failed job that started after every cancelled job of its run
  had finished; a job that failed on its own started before the cancellations
  it caused.
  """

  @real_failures ["failure", "timed_out", "startup_failure", "action_required"]

  @spec cancelled?(map(), [map()]) :: boolean()
  def cancelled?(%{"event" => event}, jobs) when event in ["merge_group", "pull_request"] and jobs != [] do
    {gates, upstream} = Enum.split_with(jobs, &gate?(&1, jobs))
    cancelled? = Enum.any?(upstream, &(&1["conclusion"] == "cancelled"))
    no_real_failure? = Enum.all?(upstream, &(&1["conclusion"] not in @real_failures))
    failed_gate? = Enum.any?(gates, &(&1["conclusion"] == "failure"))
    superseded? = Enum.any?(jobs, &(&1["name"] == "ci gate")) and Enum.all?(jobs, &(&1["conclusion"] == "cancelled"))

    superseded? or (failed_gate? and cancelled? and no_real_failure?)
  end

  def cancelled?(_run, _jobs), do: false

  defp gate?(%{"name" => "ci gate"}, _jobs), do: true

  defp gate?(%{"conclusion" => "failure"} = job, jobs) do
    cancelled = Enum.filter(jobs, &(&1["conclusion"] == "cancelled" and same_run?(&1, job)))

    with [_ | _] <- cancelled,
         {:ok, started} <- time(job["started_at"]),
         ends = Enum.map(cancelled, &time(&1["completed_at"])),
         true <- Enum.all?(ends, &match?({:ok, _}, &1)) do
      Enum.all?(ends, fn {:ok, ended} -> DateTime.compare(started, ended) != :lt end)
    else
      _ -> false
    end
  end

  defp gate?(_job, _jobs), do: false

  # Check runs carry their suite; Actions jobs carry their run id.
  defp same_run?(a, b), do: run_key(a) == run_key(b)
  defp run_key(job), do: get_in(job, ["check_suite", "id"]) || job["run_id"]

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      error -> error
    end
  end

  defp time(_value), do: :error
end
