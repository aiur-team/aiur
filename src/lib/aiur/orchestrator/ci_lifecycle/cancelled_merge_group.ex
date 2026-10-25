defmodule Aiur.Orchestrator.CiLifecycle.CancelledMergeGroup do
  @moduledoc "Keeps cancelled merge-group runs out of CI lifecycle failure transitions."

  alias Aiur.GitHub.{CIRecovery, MergeQueue, Transport}
  alias Aiur.LandingWatch.{MergeFailureClassifier, MergeGroupRunFetcher, MergeQueueFailureEvidence}

  @doc false
  @spec annotate(term(), map(), keyword()) :: term()
  def annotate({started_at, {:ok, %{results: results} = observation}}, baseline, opts) do
    previous = Map.get(baseline, :poll_cache, %{})

    results =
      Enum.map(results, fn result ->
        prior = Map.get(previous, Map.get(result, :target))

        if cancelled_queue_failure?(result, prior) and cancelled_merge_group_for_result?(result, opts) do
          Map.put(result, :cancelled_merge_group?, true)
        else
          result
        end
      end)

    {started_at, {:ok, %{observation | results: results}}}
  end

  def annotate(observation, _baseline, _opts), do: observation

  @doc false
  @spec classify_departure(map(), map() | nil) :: map()
  def classify_departure(result, previous) do
    cond do
      Map.get(result, :cancelled_merge_group?, false) ->
        Map.merge(result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})

      MergeQueue.failed_entry_dropped?(result, previous) ->
        Map.merge(result, %{
          decision: :failed,
          pending_reason: :merge_queue_dropped,
          failures: [%{name: "merge queue", kind: "merge_queue", result: "dropped after queue checks"}]
        })

      true ->
        result
    end
  end

  defp cancelled_queue_failure?(
         %{decision: :failed, pending_reason: :merge_queue_failed, head_sha: head, review_decision: "APPROVED"},
         %{head_sha: head}
       )
       when is_binary(head),
       do: true

  defp cancelled_queue_failure?(result, previous), do: MergeQueue.failed_entry_dropped?(result, previous)

  defp cancelled_merge_group_for_result?(result, opts) do
    check = Keyword.get(opts, :cancelled_merge_group_fun, &cancelled_merge_group_for_pr/2)

    case check.(Map.get(result, :pr_number), opts) do
      true -> true
      {:ok, true} -> true
      _ -> false
    end
  end

  defp cancelled_merge_group_for_pr(number, opts) when is_integer(number) do
    with {:ok, base} <- MergeGroupRunFetcher.base_branch(opts),
         {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, runs} <- MergeGroupRunFetcher.completed_runs(owner, repo, base, token, opts),
         run when is_map(run) <- Enum.find(runs, &(number in MergeQueueFailureEvidence.run_pr_numbers(&1["head_branch"], base))),
         id when is_integer(id) <- run["id"],
         {:ok, jobs} <- Keyword.get(opts, :ci_recovery_jobs_fun, &CIRecovery.jobs/2).(id, opts) do
      MergeFailureClassifier.cancelled_group?(run, jobs)
    else
      _ -> false
    end
  end

  defp cancelled_merge_group_for_pr(_number, _opts), do: false
end
