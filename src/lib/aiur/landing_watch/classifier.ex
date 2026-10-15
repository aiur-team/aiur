defmodule Aiur.LandingWatch.Classifier do
  @moduledoc "Conservative decisions for approved pull requests and Actions failures."

  alias Aiur.Events.GithubCIPoller.Evaluation

  @spec approved_at_head?(map()) :: boolean()
  def approved_at_head?(%{"reviewDecision" => "APPROVED", "headRefOid" => head, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => head}} | _]}})
      when is_binary(head) and head != "",
      do: true

  def approved_at_head?(_), do: false

  @spec ci_verdict([map()], map(), map(), keyword()) :: map()
  def ci_verdict(check_runs, commit_status, pr, opts) do
    required = Keyword.get(opts, :required_checks, {:error, :unavailable})

    Evaluation.evaluate(check_runs, commit_status)
    |> Evaluation.enforce_required_checks(check_runs, commit_status, pr, Keyword.put(opts, :required_checks, required))
  end

  @spec infra_failure?(map(), [map()]) :: boolean()
  def infra_failure?(%{decision: :failed, failures: failures}, runs) when failures != [] do
    failed_required = Enum.map(failures, & &1.name) |> MapSet.new()

    failed = Enum.filter(runs, &(Map.get(&1, "status") == "completed" and Map.get(&1, "conclusion") in ["failure", "cancelled", "timed_out", "startup_failure"]))

    failed != [] and
      Enum.all?(failed, fn run ->
        not MapSet.member?(failed_required, Map.get(run, "name")) or infrastructure_run?(run)
      end)
  end

  def infra_failure?(_, _), do: false

  @spec infrastructure_run?(map()) :: boolean()
  def infrastructure_run?(run) when is_map(run) do
    conclusion = Map.get(run, "conclusion")
    jobs = Map.get(run, "jobs", [])
    workflow_jobs = Map.get(run, "workflow_jobs", [])

    conclusion == "startup_failure" or
      (conclusion != "cancelled" and is_list(jobs) and jobs != [] and Enum.all?(jobs, &infrastructure_job?/1)) or
      cancelled_gate_dependencies?(run, workflow_jobs)
  end

  def infrastructure_run?(_), do: false

  defp cancelled_gate_dependencies?(%{"name" => "ci gate", "conclusion" => "failure"}, jobs) when is_list(jobs) and jobs != [] do
    upstream = Enum.reject(jobs, &(&1["name"] == "ci gate"))
    cancelled = Enum.filter(upstream, &(&1["conclusion"] == "cancelled"))
    real_failures = Enum.filter(upstream, &(&1["conclusion"] == "failure"))

    cancelled != [] and real_failures == [] and Enum.all?(cancelled, &infrastructure_job?/1)
  end

  defp cancelled_gate_dependencies?(_, _), do: false

  defp infrastructure_job?(job) do
    steps = Map.get(job, "steps", [])
    runner_failure? = String.contains?(String.downcase(to_string(Map.get(job, "conclusion", ""))), "runner")
    zero_work? = steps == [] or Enum.all?(steps, &(Map.get(&1, "conclusion") in [nil, "skipped", "cancelled"]))
    zero_runtime? = runtime_ms(job) == 0
    runner_failure? or zero_work? or zero_runtime?
  end

  defp runtime_ms(%{"started_at" => started, "completed_at" => completed}) when is_binary(started) and is_binary(completed) do
    with {:ok, start, _} <- DateTime.from_iso8601(started),
         {:ok, finish, _} <- DateTime.from_iso8601(completed) do
      max(DateTime.diff(finish, start, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp runtime_ms(_), do: nil
end
