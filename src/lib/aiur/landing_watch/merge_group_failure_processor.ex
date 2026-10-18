defmodule Aiur.LandingWatch.MergeGroupFailureProcessor do
  @moduledoc "Classifies failed merge-group runs and routes each PR outcome."
  alias Aiur.Alerts
  alias Aiur.GitHub.{CIRecovery, Errors, Transport}
  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{Journal, MergeFailureClassifier, MergeFailureOptions, MergeGroupFailureEvidence, MergeGroupJournal, MergeGroupRequeue}

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

    # One failing run must not hold back later runs; report the first error after trying all.
    Enum.reduce(failures, :ok, fn run, first_error ->
      result = process_claimed_failed_group(run, runs, observations, base, opts)
      if first_error == :ok, do: result, else: first_error
    end)
  end

  defp prepare_failure_evidence(opts, base) do
    opts
    |> Keyword.put(
      :recent_main_failure_paths,
      MergeGroupFailureEvidence.recent_main_paths(base, opts)
    )
    |> Keyword.put(:known_failure_patterns, MergeGroupFailureEvidence.known_patterns(opts))
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
    with {:ok, jobs} <- Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(run["id"], opts),
         {:ok, {classification, failure}} <-
           MergeFailureClassifier.classify(
             run,
             jobs,
             observations,
             classifier_options(run, prs, jobs, opts)
           ) do
      case classification do
        :infra ->
          MergeGroupRequeue.requeue_group_prs(prs, observations, run, "infrastructure failure", opts)

        :inherited ->
          MergeGroupRequeue.requeue_group_prs(prs, observations, run, "inherited merge-group failure", opts)

        :known_non_pr ->
          MergeGroupRequeue.requeue_group_prs(prs, observations, run, "known non-PR failure", opts)

        :pr_caused ->
          route_pr_caused(prs, observations, failure, run, opts)
      end
    else
      # A log GitHub no longer serves degrades only this run; the claim stays so the poll moves on.
      # Other errors release the claim; process_new_failed_group caps their retries.
      {:error, {:job_log, job_id, {:github, :http, %{status: status}} = reason}} when status in [404, 410] ->
        emit_unclassified_attention(
          "system.pr.landing.job_log_unavailable",
          run,
          prs,
          "log for job #{inspect(job_id)} is unavailable (#{inspect(reason)})",
          opts
        )

      {:error, _} = error ->
        error
    end
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

  defp classifier_options(run, prs, jobs, opts) do
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
    failures = [failure_to_map(failure)]
    run_link = run_url(run["id"], opts)

    prs
    |> Enum.map(&Enum.find(observations, fn observation -> observation.number == &1 end))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(:ok, &rework_if_ok(&1, &2, failures, run_link, opts))
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
