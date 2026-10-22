defmodule Aiur.LandingWatch.MergeQueueWatchdogEvidence do
  @moduledoc false

  alias Aiur.GitHub.CIRecovery

  alias Aiur.LandingWatch.{
    Journal,
    LocalRead,
    MergeFailureClassifier,
    MergeGroupFailureProcessor,
    MergeQueueFailureEvidence
  }

  @failed_conclusions ["failure", "cancelled", "timed_out", "startup_failure"]
  @spec classify(map(), keyword()) :: {:ok, map()} | {:skip, term()} | {:error, term()}
  def classify(observation, opts) do
    runs = Keyword.get(opts, :completed_merge_group_runs, [])
    observations = Keyword.get(opts, :all_observations, [observation])
    base = Keyword.get(opts, :base_branch, Aiur.Config.base_branch())
    since_ms = Keyword.get(opts, :unmergeable_since_ms, 0)

    candidates =
      runs
      |> Enum.filter(&candidate_run?(&1, observation.number, base, since_ms))
      |> Enum.sort_by(&run_time_ms/1)

    case Journal.state(opts) do
      {:ok, state} ->
        classify_candidates(
          candidates,
          state,
          observation,
          observations,
          runs,
          base,
          since_ms,
          opts
        )

      {:error, _} = error ->
        error
    end
  end

  defp classify_candidates(
         [],
         _state,
         _observation,
         _observations,
         _runs,
         _base,
         _since_ms,
         _opts
       ),
       do: {:skip, :no_completed_failed_merge_group}

  defp classify_candidates(
         candidates,
         state,
         observation,
         observations,
         runs,
         base,
         since_ms,
         opts
       ) do
    key = "#{observation.number}:#{observation.head}"

    cached =
      get_in(state, ["unmergeable_queue_entries", key, "classified_merge_group_runs"]) || %{}

    {updated_cache, changed?} =
      Enum.reduce(candidates, {cached, false}, fn run, {cache, changed?} ->
        cache_key = Integer.to_string(run["id"])

        cache_candidate(cache, changed?, cache_key, run, observation, observations, base, opts)
      end)

    case persist_cache(key, updated_cache, changed?, opts) do
      :ok ->
        latest = List.last(candidates)

        case Map.fetch(updated_cache, Integer.to_string(latest["id"])) do
          {:ok, record} ->
            render_record(record, latest, observation, observations, runs, base, since_ms)

          :error ->
            {:skip, :merge_group_evidence_unavailable}
        end

      {:error, _} = error ->
        error
    end
  end

  defp cache_candidate(cache, changed?, key, run, observation, observations, base, opts) do
    case Map.fetch(cache, key) do
      {:ok, _record} -> {cache, changed?}
      :error -> cache_fresh_run(cache, changed?, key, run, observation, observations, base, opts)
    end
  end

  defp cache_fresh_run(cache, changed?, key, run, observation, observations, base, opts) do
    case classify_run(run, observation, observations, base, opts) do
      {:ok, record} -> {Map.put(cache, key, record), true}
      {:retry, _reason} -> {cache, changed?}
    end
  end

  defp candidate_run?(run, number, base, since_ms) do
    run["conclusion"] in @failed_conclusions and is_integer(run["id"]) and
      number in MergeQueueFailureEvidence.run_pr_numbers(run["head_branch"], base) and
      is_integer(since_ms) and is_integer(run_time_ms(run)) and run_time_ms(run) >= since_ms
  end

  defp classify_run(run, _observation, observations, base, opts) do
    prs = MergeQueueFailureEvidence.run_pr_numbers(run["head_branch"], base)
    related_observations = Enum.filter(observations, &(&1.number in prs))

    with {:ok, jobs} <-
           LocalRead.run(
             Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2),
             [run["id"], opts],
             opts
           ),
         {:ok, {classification, failure}} <-
           MergeFailureClassifier.classify(
             run,
             jobs,
             related_observations,
             Keyword.get(
               opts,
               :failure_classifier_options_fun,
               &MergeGroupFailureProcessor.classifier_options/4
             ).(
               run,
               prs,
               jobs,
               opts
             )
           ) do
      {:ok, record(classification, failure, run["id"])}
    else
      {:error, reason} -> {:retry, reason}
      other -> {:retry, other}
    end
  end

  defp record(:pr_caused, _failure, run_id),
    do: %{"verdict" => "skip", "reason" => "pr_caused_merge_group_failure", "run_id" => run_id}

  defp record(classification, failure, run_id)
       when classification in [:infra, :inherited, :known_non_pr] do
    log = if is_map(failure), do: failure[:log], else: ""

    %{
      "verdict" => "ok",
      "classification" => Atom.to_string(classification),
      "failing_tests" => MergeQueueFailureEvidence.test_names(log || ""),
      "run_id" => run_id
    }
  end

  defp record(_classification, _failure, _run_id),
    do: raise(ArgumentError, "merge-group failure classification is not definitive")

  defp persist_cache(_key, _cache, false, _opts), do: :ok

  defp persist_cache(key, cache, true, opts) do
    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key, %{"attempts" => 0})
      updated = Map.put(row, "classified_merge_group_runs", cache)
      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, updated))}
    end)
  end

  defp render_record(
         %{"verdict" => "ok"} = record,
         _run,
         observation,
         observations,
         runs,
         base,
         since_ms
       ) do
    {:ok,
     %{
       classification: classification(record["classification"]),
       failing_tests: record["failing_tests"] || [],
       rebuilt_groups:
         MergeQueueFailureEvidence.rebuilt_group_count(
           runs,
           observation,
           observations,
           base,
           since_ms
         ),
       run_id: record["run_id"]
     }}
  end

  defp render_record(
         %{"reason" => "pr_caused_merge_group_failure"},
         _run,
         _observation,
         _observations,
         _runs,
         _base,
         _since
       ),
       do: {:skip, :pr_caused_merge_group_failure}

  defp render_record(_record, _run, _observation, _observations, _runs, _base, _since),
    do: {:skip, :cached_merge_group_evidence_unavailable}

  defp classification("infra"), do: :infra
  defp classification("inherited"), do: :inherited
  defp classification("known_non_pr"), do: :known_non_pr

  defp run_time_ms(run) do
    case DateTime.from_iso8601(run["run_started_at"] || run["created_at"] || "") do
      {:ok, time, _} -> DateTime.to_unix(time, :millisecond)
      _ -> nil
    end
  end
end
