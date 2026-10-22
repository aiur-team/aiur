defmodule Aiur.LandingWatch.MergeGroupFailureProcessor do
  @moduledoc "Classifies failed merge-group runs and routes each PR outcome."
  alias Aiur.Alerts
  alias Aiur.GitHub.{CIRecovery, Errors, Transport}
  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{Journal, MergeFailureClassifier, MergeFailureOptions, MergeGroupFailureEvidence, MergeGroupJournal, MergeGroupRequeue, QuarantineEvidence}

  require Logger

  # A run that fails to classify this many polls in a row keeps its claim and raises an attention.
  @lasting_failure_polls 5

  @spec process_completed([map()], [map()], String.t(), keyword()) :: :ok | {:error, term()}
  def process_completed(runs, observations, base, opts) do
    failures =
      Enum.filter(
        runs,
        &(&1["conclusion"] in ["failure", "cancelled", "timed_out", "startup_failure"] and
            is_integer(&1["id"]))
      )

    has_observed_pr? =
      Enum.any?(failures, fn run ->
        Enum.any?(
          pr_numbers(run["head_branch"]),
          &Enum.any?(observations, fn pr -> pr.number == &1 end)
        )
      end)

    opts = if has_observed_pr?, do: prepare_failure_evidence(opts, base), else: opts
    store_watchdog_evidence(runs, observations, opts)

    # One failing run must not hold back later runs; report the first error after trying all.
    Enum.reduce(failures, :ok, fn run, first_error ->
      result = process_claimed_failed_group(run, runs, observations, base, opts)
      if first_error == :ok, do: result, else: first_error
    end)
  end

  defp prepare_failure_evidence(opts, base) do
    case MergeGroupFailureEvidence.recent_main_paths(base, opts) do
      {:ok, paths} ->
        opts
        |> Keyword.put(:merge_group_failure_evidence_prepared, true)
        |> Keyword.put(:recent_main_failure_paths, paths)
        |> Keyword.put(:known_failure_patterns, MergeGroupFailureEvidence.known_patterns(opts))

      {:error, reason} ->
        Logger.warning("merge-group blame evidence unavailable; using legacy routing reason=#{inspect(reason)}")
        Keyword.put(opts, :blame_evidence_error, reason)
    end
  end

  defp store_watchdog_evidence(runs, observations, opts) do
    case Keyword.get(opts, :merge_group_evidence_fun) do
      fun when is_function(fun, 3) -> fun.(runs, observations, opts)
      _ -> :ok
    end
  end

  defp process_claimed_failed_group(run, runs, observations, base, opts) do
    case Journal.claim_merge_group_run(run["id"], opts) do
      {:ok, :already_claimed} -> :ok
      {:ok, :new} -> process_new_failed_group(run, runs, observations, base, opts)
      {:error, _} = error -> error
    end
  end

  defp process_new_failed_group(run, runs, observations, base, opts) do
    case process_failed_group(run, runs, observations, base, opts) do
      :ok ->
        _ = MergeGroupJournal.clear_merge_group_run_failures(run["id"], opts)
        :ok

      {:error, reason} = error ->
        if throttled?(reason) do
          _ = Journal.release_merge_group_run(run["id"], opts)
          error
        else
          release_counted_failure(run, base, reason, error, opts)
        end
    end
  end

  # Budget holds and GitHub rate limits throttle every run, not this one, so they retry uncounted.
  defp throttled?({:job_log, _job_id, reason}), do: throttled?(reason)
  defp throttled?({:github, :rate_limited, _}), do: true
  defp throttled?(reason), do: Errors.outcome({:error, reason}) == :held

  defp release_counted_failure(run, base, reason, error, opts) do
    case MergeGroupJournal.release_failed_merge_group_run(run["id"], @lasting_failure_polls, opts) do
      {:ok, :kept} -> emit_lasting_failure_attention(run, base, reason, opts)
      _ -> error
    end
  end

  defp emit_lasting_failure_attention(run, base, reason, opts) do
    {:ok, prs} = run_prs(run, base)

    emit_unclassified_attention(
      "system.pr.landing.merge_group_unclassified",
      run,
      prs,
      "#{@lasting_failure_polls} consecutive polls failed (last error: #{inspect(reason)})",
      opts
    )
  end

  defp process_failed_group(run, runs, observations, base, opts) do
    case run_prs(run, base) do
      {:ok, []} -> :ok
      {:ok, prs} -> process_failed_group_for_prs(run, runs, observations, prs, opts)
    end
  end

  defp process_failed_group_for_prs(run, _runs, observations, prs, opts) do
    case Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(run["id"], opts) do
      {:ok, jobs} -> classify_and_route(run, observations, prs, jobs, opts)
      {:error, _} = error -> error
    end
  end

  defp classify_and_route(run, observations, prs, jobs, opts) do
    blame_opts = classifier_options(run, prs, jobs, opts)

    case MergeFailureClassifier.classify(run, jobs, observations, blame_opts) do
      {:ok, {classification, failure}} ->
        route_classification(classification, failure, run, observations, prs, blame_opts, opts)

      {:error, {:job_log, job_id, {:github, :http, %{status: status}} = reason}} when status in [404, 410] ->
        emit_unclassified_attention("system.pr.landing.job_log_unavailable", run, prs, "log for job #{inspect(job_id)} is unavailable (#{inspect(reason)})", opts)

      {:error, _} = error ->
        error
    end
  end

  defp route_classification(:infra, _failure, run, observations, prs, _blame_opts, opts),
    do: MergeGroupRequeue.requeue_group_prs(prs, observations, run, "infrastructure failure", opts)

  defp route_classification(:inherited, _failure, run, observations, prs, _blame_opts, opts),
    do: MergeGroupRequeue.requeue_group_prs(prs, observations, run, "inherited merge-group failure", opts)

  defp route_classification(classification, failure, run, observations, prs, blame_opts, opts)
       when classification in [:known_non_pr, :pr_caused] do
    case blamed_pr(failure, prs, blame_opts) do
      {:culprits, numbers} -> route_blame_result(numbers, prs, observations, failure, run, opts)
      {:mixed, numbers} -> route_blame_result(numbers, prs, observations, failure, run, opts)
      :none -> route_innocent(prs, observations, run, failure, "untouched failing test", opts)
      _ -> route_unresolved(classification, failure, run, observations, prs, opts)
    end
  end

  defp route_blame_result(culprits, prs, observations, failure, run, opts) do
    innocent = prs -- culprits

    with :ok <- MergeGroupRequeue.requeue_group_prs(innocent, observations, run, "group contained a PR-caused failure", opts),
         do: route_failed_prs(culprits, observations, failure, run, opts)
  end

  defp route_unresolved(:known_non_pr, _failure, run, observations, prs, opts) do
    Logger.warning("merge-group blame evidence incomplete; using legacy routing run=#{run["id"]}")
    MergeGroupRequeue.requeue_group_prs(prs, observations, run, "known non-PR failure", opts)
  end

  defp route_unresolved(:pr_caused, failure, run, observations, prs, opts) do
    if Keyword.has_key?(opts, :blame_evidence_error), do: Logger.warning("merge-group blame evidence fetch failed; using legacy routing run=#{run["id"]}")
    route_pr_caused(prs, observations, failure, run, opts)
  end

  defp emit_unclassified_attention(name, run, prs, detail, opts) do
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

    message =
      "Merge-group run #{run["id"]} for PR #{Enum.map_join(prs, ", ", &"##{&1}")} was not classified: #{detail}."

    emitter.(name,
      central: true,
      durable: true,
      needs_attention: true,
      message: message,
      reason: message
    )

    :ok
  end

  @doc false
  @spec classifier_options(map(), [integer()], [map()], keyword()) :: keyword()
  def classifier_options(run, prs, jobs, opts) do
    MergeFailureOptions.build(run, prs, jobs, opts, &MergeGroupFailureEvidence.job_log/2)
  end

  # A run whose failure is a quarantined test did not fail because of its PRs.
  defp route_pr_caused(prs, observations, failure, run, opts) do
    if run["id"] in Keyword.get(opts, :quarantined_run_ids, []),
      do: MergeGroupRequeue.requeue_group_prs(prs, observations, run, "a quarantined flaky test", opts),
      else: route_failed_prs(prs, observations, failure, run, opts)
  end

  defp route_failed_prs(_prs, _observations, nil, _run, _opts), do: :ok

  defp route_failed_prs(prs, observations, failure, run, opts) do
    _ = record_blame(run, prs, failure, :pr_caused, opts)
    failures = [failure_to_map(failure)]
    run_link = run_url(run["id"], opts)

    prs
    |> Enum.map(&Enum.find(observations, fn observation -> observation.number == &1 end))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(:ok, &rework_if_ok(&1, &2, failures, run_link, opts))
  end

  defp blamed_pr(%{log: log, blame_complete: true}, prs, opts) when is_binary(log) do
    with false <- Keyword.has_key?(opts, :blame_evidence_error),
         paths when paths != [] <- failure_paths(log) do
      paths_blame(paths, log, prs, opts)
    else
      _ -> :unknown
    end
  end

  defp blamed_pr(_, _, _), do: :unknown

  defp paths_blame(paths, log, prs, opts) do
    results = Enum.map(paths, &path_blame(&1, log, prs, opts))

    culprits =
      results
      |> Enum.flat_map(fn
        {:culprits, numbers} -> numbers
        _ -> []
      end)
      |> Enum.uniq()

    cond do
      Enum.any?(results, &(&1 == :unknown)) -> :unknown
      culprits == [] -> :none
      Enum.any?(results, &(&1 == :none)) -> {:mixed, culprits}
      true -> {:culprits, culprits}
    end
  end

  defp path_blame(path, log, prs, opts) do
    case touched_prs(path, prs, opts) do
      [number] -> {:culprits, [number]}
      [] -> if known_failure?(path, log, opts), do: :none, else: :unknown
      _ -> :unknown
    end
  end

  defp touched_prs(path, prs, opts) do
    Enum.filter(prs, fn pr ->
      case get_in(opts, [:changed_paths_by_pr, pr]) do
        paths when is_list(paths) -> QuarantineEvidence.touched?(path, paths)
        _ -> false
      end
    end)
  end

  defp known_failure?(path, log, opts) do
    path in Keyword.get(opts, :recent_main_failure_paths, []) or
      Enum.any?(Keyword.get(opts, :known_failure_patterns, []), &String.contains?(String.downcase(log), String.downcase(&1)))
  end

  defp failure_paths(log), do: MergeGroupFailureEvidence.test_paths(log)

  defp route_innocent(prs, observations, run, failure, reason, opts) do
    {repeat, first} = split_repeated_heads(prs, observations, opts)

    _ = record_blame(run, prs, failure, if(repeat == [], do: :innocent_requeued, else: :repeat_ejected), opts)

    case MergeGroupRequeue.requeue_group_prs(first, observations, run, reason, opts) do
      :ok ->
        with :ok <- record_requeued_heads(first, observations, opts),
             do: rework_repeat_prs(repeat, observations, failure, run, opts)

      {:error, _} = error ->
        error
    end
  end

  defp split_repeated_heads(prs, observations, opts) do
    Enum.split_with(prs, &repeat_head?(&1, observations, opts))
  end

  defp repeat_head?(number, observations, opts) do
    case Enum.find(observations, &(&1.number == number)) do
      %{head: head} when is_binary(head) ->
        case Journal.merge_group_blame_attempts(number, head, opts) do
          {:ok, count} -> count >= 1
          _ -> false
        end

      _ ->
        false
    end
  end

  defp record_requeued_heads(prs, observations, opts) do
    Enum.reduce_while(prs, :ok, &record_requeued_head(&1, &2, observations, opts))
  end

  defp record_requeued_head(number, :ok, observations, opts) do
    case Enum.find(observations, &(&1.number == number)) do
      %{head: head} when is_binary(head) ->
        case Journal.record_merge_group_blame_attempt(number, head, opts) do
          {:ok, _count} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      _ ->
        {:cont, :ok}
    end
  end

  defp rework_repeat_prs([], _observations, _failure, _run, _opts), do: :ok

  defp rework_repeat_prs(prs, observations, failure, run, opts) do
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

    Enum.each(prs, fn number ->
      message = "PR ##{number} was removed after the same head failed an innocent merge-group requeue twice."
      emitter.("system.pr.landing.merge_group_repeat_failure", central: true, durable: true, needs_attention: true, message: message, reason: "same_head_failed_twice")
    end)

    route_failed_prs(prs, observations, failure, run, opts)
  end

  defp record_blame(run, prs, failure, decision, opts) do
    Journal.record_failure_observation(
      %{
        "identity" => "merge-group-blame:#{run["id"]}",
        "source" => "merge_group_blame",
        "run_id" => run["id"],
        "group_prs" => prs,
        "decision" => to_string(decision),
        "at_ms" => Keyword.get(opts, :now_ms, System.system_time(:millisecond)),
        "path" => if(is_map(failure), do: failure |> Map.get(:log, "") |> failure_paths() |> List.first())
      },
      opts
    )
  end

  defp failure_to_map(failure),
    do: %{
      name: failure.job["name"] || "Failed merge-group test",
      excerpt: String.slice(failure.log, 0, 500)
    }

  defp run_url(run_id, opts) do
    case Keyword.get(opts, :repo_fun, &Transport.parse_repo/0).() do
      {:ok, {owner, repo}} -> "https://github.com/#{owner}/#{repo}/actions/runs/#{run_id}"
      _ -> "https://github.com/actions/runs/#{run_id}"
    end
  end

  defp rework_if_ok(_pr, {:error, _} = error, _failures, _run_link, _opts), do: error

  defp rework_if_ok(pr, :ok, failures, run_link, opts),
    do: LandingWatch.rework(pr, failures, Keyword.put(opts, :run_url, run_link))

  defp run_prs(run, base) do
    branch = Map.get(run, "head_branch", "")
    prefix = "gh-readonly-queue/#{base}/"
    prs = if is_binary(branch) and String.starts_with?(branch, prefix), do: pr_numbers(branch), else: []
    {:ok, prs}
  end

  defp pr_numbers(branch) when is_binary(branch) do
    Regex.scan(~r/pr-(\d+)-/, branch, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)
    |> Enum.uniq()
  end

  defp pr_numbers(_), do: []
end
