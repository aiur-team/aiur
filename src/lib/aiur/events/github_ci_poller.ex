defmodule Aiur.Events.GithubCIPoller do
  @moduledoc """
  Polls GitHub CI state for the current head of canonical Aiur pull requests.

  GitHub publishes modern check runs and legacy commit statuses through
  separate APIs. This module reads both for each current PR head, classifies the
  aggregate conservatively, and leaves label changes plus event publication to
  the orchestrator.
  """

  require Logger

  alias Aiur.{CIApprovalStore, Config}
  alias Aiur.GitHub.Client

  @type target :: String.t() | integer()
  @type decision :: :pending | :passed | :failed

  @successful_conclusions ~w(success neutral skipped)
  @failed_statuses ~w(error failure)
  @failed_conclusions ~w(action_required failure startup_failure timed_out)
  @terminal_check_conclusions @successful_conclusions ++ @failed_conclusions
  @default_max_concurrency 4
  @default_target_timeout 60_000

  @spec poll([target()], keyword()) :: {:ok, %{results: [map()], errors: [{String.t(), term()}]}}
  def poll(targets, opts \\ []) when is_list(targets) do
    targets = normalize_targets(targets)

    results =
      targets
      |> target_task_results(opts)
      |> Enum.zip(targets)
      |> Enum.map(fn
        {{:ok, result}, _target} -> result
        {{:exit, reason}, target} -> poll_error(target, {:target, {:exit, reason}})
      end)

    errors =
      results
      |> Enum.flat_map(fn
        %{target: target, error: error} -> [{target, error}]
        _ -> []
      end)

    {:ok, %{results: results, errors: errors}}
  end

  defp target_task_results(targets, opts) do
    run_target = &poll_target(&1, opts)

    task_opts = [
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      timeout: Keyword.get(opts, :timeout, @default_target_timeout),
      on_timeout: :kill_task
    ]

    case Process.whereis(Aiur.TaskSupervisor) do
      pid when is_pid(pid) ->
        pid
        |> Task.Supervisor.async_stream_nolink(targets, run_target, task_opts)
        |> Enum.to_list()

      nil ->
        previous_trap_exit = Process.flag(:trap_exit, true)

        try do
          targets
          |> Task.async_stream(run_target, task_opts)
          |> Enum.to_list()
        after
          Process.flag(:trap_exit, previous_trap_exit)
        end
    end
  end

  @doc false
  @spec evaluate_for_test([map()], map()) :: %{decision: decision(), failures: [map()]}
  def evaluate_for_test(check_runs, commit_status) when is_list(check_runs) and is_map(commit_status) do
    evaluate(check_runs, commit_status)
  end

  defp poll_target(target, opts) do
    case ci_batch_value(opts, target) do
      {:ok, batch} -> poll_batched_target(target, batch, opts)
      :missing -> poll_target_from_rest(target, opts)
    end
  end

  defp poll_target_from_rest(target, opts) do
    case Client.fetch_open_pull_request_for_branch(target, opts) do
      {:ok, nil} ->
        # A newly finalized PR can take a short time to appear in GitHub's
        # branch-filtered listing. Fail closed so the tracker does not stay
        # human-review-ready before its current head can be evaluated.
        %{target: target, decision: :pending, pending_reason: :open_pr_not_yet_visible}

      {:ok, pr} when is_map(pr) ->
        poll_open_pull_request(target, pr, opts)

      {:error, reason} ->
        poll_error(target, {:pr_lookup, reason})
    end
  end

  defp poll_batched_target(target, %{delivered: true} = delivered, _opts) do
    # A target the CI poll batch displaced because a webhook check-run delivery
    # answered it since the last read (#2310). The delivery skipped the read the
    # batch would have paid for; this result carries no verdict and the
    # lifecycle treats it as inert (`delivered: true`), because a CI verdict is
    # never answered from a held body at any age (R10). The real verdict comes
    # from the next non-displaced read, which `PollSnapshots`'s delivery-fresh
    # window bounds — once the snapshot ages out, the poll fetches again.
    %{
      target: target,
      delivered: true,
      head_sha: Map.get(delivered, :head_sha),
      pr_number: Map.get(delivered, :pr_number)
    }
  end

  defp poll_batched_target(target, %{pull_request: nil}, _opts) do
    %{target: target, decision: :pending, pending_reason: :open_pr_not_yet_visible}
  end

  defp poll_batched_target(target, %{pull_request: pr, check_runs: check_runs, commit_status: commit_status}, opts)
       when is_map(pr) and is_list(check_runs) and is_map(commit_status) do
    with {:ok, pr_number} <- positive_integer(Map.get(pr, "number")),
         {:ok, head_sha} <- head_sha(pr) do
      expected_base = expected_base_branch(opts)

      case ensure_pull_request_base(target, pr, head_sha, expected_base, opts) do
        {:ok, :unchanged} ->
          evaluate(check_runs, commit_status)
          |> enforce_base_repair_invalidation(target, head_sha, check_runs, commit_status, opts)
          |> Map.merge(%{target: target, pr_number: pr_number, head_sha: head_sha})
          |> Map.merge(merge_queue_observation(pr))
          |> log_classification()

        {:ok, {:unchanged, recovered_invalidation}} ->
          evaluate(check_runs, commit_status)
          |> enforce_base_repair_invalidation(target, head_sha, check_runs, commit_status, opts)
          |> Map.merge(%{target: target, pr_number: pr_number, head_sha: head_sha, base_repair_invalidation: recovered_invalidation})
          |> Map.merge(merge_queue_observation(pr))
          |> log_classification()

        {:ok, {:repaired, invalidation}} ->
          base_branch_repaired(target, pr_number, invalidation, expected_base)

        {:error, reason, invalidation} ->
          base_branch_failure(target, pr_number, head_sha, expected_base, reason, invalidation)
      end
    else
      {:error, reason} -> poll_error(target, reason)
    end
  end

  defp poll_batched_target(target, _batch, _opts), do: poll_error(target, :invalid_ci_poll_batch)

  defp ci_batch_value(opts, target) do
    with %{} = batch <- Keyword.get(opts, :ci_batch),
         {:ok, value} <- Map.fetch(batch, target) do
      {:ok, value}
    else
      _ -> :missing
    end
  end

  # Carries the batch's merge-queue recovery observation (ready/approved/
  # mergeable/armed/queued) into the poll result so CiLifecycle can alert on a
  # parked-ready PR. Absent on the REST fallback path and on error/no-PR
  # results; CiLifecycle treats a missing observation as `:unknown` (fail
  # closed) instead of arming or clearing a recovery signal on partial data.
  defp merge_queue_observation(%{} = pr) do
    case Map.get(pr, "merge_queue") do
      %{} = observation when map_size(observation) > 0 -> observation
      _other -> %{}
    end
  end

  defp poll_open_pull_request(target, pr, opts) do
    with {:ok, pr_number} <- positive_integer(Map.get(pr, "number")),
         {:ok, head_sha} <- head_sha(pr) do
      expected_base = expected_base_branch(opts)

      case ensure_pull_request_base(target, pr, head_sha, expected_base, opts) do
        {:ok, :unchanged} ->
          poll_open_pull_request_ci(target, pr_number, head_sha, opts)

        {:ok, {:unchanged, recovered_invalidation}} ->
          opts = put_base_repair_invalidation(opts, target, recovered_invalidation)

          target
          |> poll_open_pull_request_ci(pr_number, head_sha, opts)
          |> Map.put(:base_repair_invalidation, recovered_invalidation)

        {:ok, {:repaired, invalidation}} ->
          base_branch_repaired(target, pr_number, invalidation, expected_base)

        {:error, reason, invalidation} ->
          base_branch_failure(target, pr_number, head_sha, expected_base, reason, invalidation)
      end
    else
      {:error, reason} -> poll_error(target, reason)
    end
  end

  defp poll_open_pull_request_ci(target, pr_number, head_sha, opts) do
    case Client.fetch_commit_ci_status(head_sha, opts) do
      {:ok, %{check_runs: check_runs, commit_status: commit_status}} ->
        poll_current_head_result(target, pr_number, head_sha, check_runs, commit_status, opts)

      {:error, reason} ->
        poll_error(target, reason)
    end
  end

  defp poll_current_head_result(target, pr_number, observed_head_sha, check_runs, commit_status, opts) do
    case Client.fetch_open_pull_request_for_branch(target, opts) do
      {:ok, current_pr} when is_map(current_pr) ->
        poll_current_pull_request_result(
          target,
          pr_number,
          current_pr,
          observed_head_sha,
          check_runs,
          commit_status,
          opts
        )

      {:ok, nil} ->
        %{target: target, decision: :pending, pending_reason: :open_pr_no_longer_visible}

      {:error, reason} ->
        poll_error(target, {:pr_recheck, reason})
    end
  end

  defp poll_current_pull_request_result(
         target,
         pr_number,
         current_pr,
         observed_head_sha,
         check_runs,
         commit_status,
         opts
       ) do
    expected_base = expected_base_branch(opts)

    case head_sha(current_pr) do
      {:ok, current_head_sha} ->
        case ensure_pull_request_base(target, current_pr, current_head_sha, expected_base, opts) do
          {:ok, :unchanged} ->
            current_head_result(target, pr_number, current_pr, observed_head_sha, check_runs, commit_status, opts)

          {:ok, {:unchanged, recovered_invalidation}} ->
            opts = put_base_repair_invalidation(opts, target, recovered_invalidation)

            target
            |> current_head_result(
              pr_number,
              current_pr,
              observed_head_sha,
              check_runs,
              commit_status,
              opts
            )
            |> Map.put(:base_repair_invalidation, recovered_invalidation)

          {:ok, {:repaired, invalidation}} ->
            base_branch_repaired(target, pr_number, invalidation, expected_base)

          {:error, reason, invalidation} ->
            base_branch_failure(
              target,
              pr_number,
              current_head_sha,
              expected_base,
              reason,
              invalidation
            )
        end

      {:error, reason} ->
        poll_error(target, reason)
    end
  end

  defp current_head_result(target, pr_number, current_pr, observed_head_sha, check_runs, commit_status, opts) do
    case head_sha(current_pr) do
      {:ok, ^observed_head_sha} ->
        evaluate(check_runs, commit_status)
        |> enforce_base_repair_invalidation(target, observed_head_sha, check_runs, commit_status, opts)
        |> Map.merge(%{
          target: target,
          pr_number: pr_number,
          head_sha: observed_head_sha,
          draft?: pr_draft?(current_pr),
          review_decision: Map.get(current_pr, "review_decision")
        })
        |> log_classification()

      {:ok, current_head_sha} ->
        %{
          target: target,
          pr_number: pr_number,
          head_sha: current_head_sha,
          decision: :pending,
          pending_reason: :head_changed
        }

      {:error, reason} ->
        poll_error(target, reason)
    end
  end

  defp evaluate(check_runs, commit_status) do
    check_runs = blocking_check_runs(check_runs)
    statuses = commit_status |> Map.get("statuses", []) |> Enum.filter(&is_map/1)
    failed_checks = failed_check_runs(check_runs) ++ failed_commit_statuses(statuses)

    failed_checks =
      if failed_checks == [] do
        failed_combined_status(commit_status)
      else
        failed_checks
      end

    classification =
      cond do
        incomplete_check_runs?(check_runs) -> {:pending, :check_runs_incomplete}
        incomplete_commit_statuses?(statuses) -> {:pending, :commit_statuses_incomplete}
        incomplete_combined_status?(commit_status) -> {:pending, :combined_status_incomplete}
        failed_checks != [] -> {:failed, nil}
        observed_ci_signal?(check_runs, statuses, commit_status) -> {:passed, nil}
        true -> {:pending, :ci_not_observed}
      end

    evaluation(classification, failed_checks)
  end

  defp non_blocking_check?(check_run) do
    case Map.get(check_run, "name") do
      name when is_binary(name) ->
        name |> String.trim() |> String.downcase() |> String.ends_with?("(non-blocking)")

      _ ->
        false
    end
  end

  defp blocking_check_runs(check_runs) do
    check_runs
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&non_blocking_check?/1)
  end

  defp evaluation({:pending, pending_reason}, failed_checks) do
    %{decision: :pending, pending_reason: pending_reason, failures: failed_checks}
  end

  defp evaluation({decision, nil}, failed_checks) do
    %{decision: decision, failures: failed_checks}
  end

  defp enforce_base_repair_invalidation(result, target, head_sha, check_runs, commit_status, opts) do
    invalidations = Keyword.get(opts, :base_repair_invalidations, %{})

    case Map.get(invalidations, to_string(target)) do
      %{repair_state: :repairing} ->
        require_base_repair_recovery(result)

      %{"repair_state" => "repairing"} ->
        require_base_repair_recovery(result)

      %{head_sha: ^head_sha, repaired_at: repaired_at} when is_integer(repaired_at) ->
        apply_base_repair_invalidation(result, check_runs, commit_status, repaired_at)

      %{"head_sha" => ^head_sha, "repaired_at" => repaired_at}
      when is_integer(repaired_at) ->
        apply_base_repair_invalidation(result, check_runs, commit_status, repaired_at)

      _ ->
        result
    end
  end

  # A pre-PATCH marker has no trustworthy completion timestamp. It can never
  # validate CI directly: the next poll first observes the repaired base, then
  # journals a confirmed marker whose timestamp is safely after that
  # observation.
  defp require_base_repair_recovery(result) do
    result
    |> Map.put(:decision, :pending)
    |> Map.put(:failures, [])
    |> Map.put(:pending_reason, :base_repair_confirmation_required)
  end

  defp apply_base_repair_invalidation(result, check_runs, commit_status, repaired_at) do
    if result.decision in [:passed, :failed] and post_repair_ci?(check_runs, commit_status, repaired_at) do
      Map.put(result, :base_repair_revalidated, true)
    else
      result
      |> Map.put(:decision, :pending)
      |> Map.put(:failures, [])
      |> Map.put(:pending_reason, :base_repair_ci_revalidation_required)
    end
  end

  defp post_repair_ci?(check_runs, commit_status, repaired_at) do
    check_evidence = check_runs |> blocking_check_runs() |> Enum.map(&ci_evidence_timestamp/1)

    status_evidence =
      commit_status
      |> Map.get("statuses", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&ci_evidence_timestamp/1)

    evidence = check_evidence ++ status_evidence
    evidence != [] and Enum.all?(evidence, &(is_integer(&1) and &1 > repaired_at))
  end

  defp ci_evidence_timestamp(evidence) when is_map(evidence) do
    [
      get_in(evidence, ["check_suite", "created_at"]),
      Map.get(evidence, "created_at"),
      Map.get(evidence, "started_at")
    ]
    |> Enum.map(&timestamp_seconds/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp ci_evidence_timestamp(_evidence), do: nil

  defp timestamp_seconds(value) when is_integer(value) and value >= 0, do: value

  defp timestamp_seconds(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> nil
    end
  end

  defp timestamp_seconds(_value), do: nil

  defp failed_check_runs(check_runs) do
    Enum.flat_map(check_runs, fn check_run ->
      status = Map.get(check_run, "status")
      conclusion = Map.get(check_run, "conclusion")

      if status == "completed" and conclusion in @failed_conclusions do
        [check_failure(check_run, "check_run", conclusion)]
      else
        []
      end
    end)
  end

  defp failed_commit_statuses(statuses) do
    Enum.flat_map(statuses, fn status ->
      state = Map.get(status, "state")

      if state in @failed_statuses do
        [check_failure(status, "commit_status", state)]
      else
        []
      end
    end)
  end

  defp failed_combined_status(%{"state" => state}) when state in @failed_statuses do
    [%{name: "combined commit status", kind: "commit_status", result: state, excerpt: nil}]
  end

  defp failed_combined_status(_commit_status), do: []

  defp check_failure(check, kind, result) do
    output = Map.get(check, "output", %{})

    %{
      name: Map.get(check, "name") || Map.get(check, "context") || "unnamed check",
      kind: kind,
      result: result,
      excerpt: Map.get(output, "summary") || Map.get(output, "text") || Map.get(check, "description")
    }
  end

  defp incomplete_check_runs?(check_runs) do
    Enum.any?(check_runs, fn check_run ->
      status = Map.get(check_run, "status")
      conclusion = Map.get(check_run, "conclusion")

      status != "completed" or conclusion not in @terminal_check_conclusions
    end)
  end

  defp incomplete_commit_statuses?(statuses) do
    Enum.any?(statuses, fn status -> Map.get(status, "state") not in ["success" | @failed_statuses] end)
  end

  defp incomplete_combined_status?(%{"state" => state, "statuses" => [_ | _]}) when is_binary(state) do
    state not in ["success" | @failed_statuses]
  end

  defp incomplete_combined_status?(_commit_status), do: false

  defp observed_ci_signal?(check_runs, statuses, %{"state" => state})
       when is_binary(state) and state != "",
       do: check_runs != [] or statuses != [] or state in ["success" | @failed_statuses]

  defp observed_ci_signal?(check_runs, statuses, _commit_status), do: check_runs != [] or statuses != []

  defp log_classification(result) do
    Logger.debug(fn ->
      "GithubCIPoller classified: issue=#{result.target} pr=#{result.pr_number} " <>
        "head=#{result.head_sha} decision=#{result.decision} " <>
        "pending_reason=#{inspect(Map.get(result, :pending_reason))} " <>
        "failure_count=#{length(Map.get(result, :failures, []))}"
    end)

    result
  end

  defp normalize_targets(targets) do
    targets
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp expected_base_branch(opts), do: Config.base_branch(opts)

  defp ensure_pull_request_base(target, pr, head_sha, expected_base, opts) do
    repair_started_at = system_time_seconds(opts)

    repairing = %{
      head_sha: head_sha,
      repaired_at: repair_started_at,
      repair_state: :repairing
    }

    ensure_opts =
      Keyword.put(opts, :before_base_repair_fun, fn ->
        journal_base_repair(target, repairing, opts)
      end)

    case Client.ensure_pull_request_base(pr, expected_base, ensure_opts) do
      {:ok, :unchanged} ->
        recover_interrupted_base_repair(target, pr, head_sha, expected_base, opts)

      {:ok, {:repaired, confirmed_head_sha}} ->
        confirmed = %{
          head_sha: confirmed_head_sha,
          repaired_at: system_time_seconds(opts),
          repair_state: :repaired
        }

        case journal_base_repair(target, confirmed, opts) do
          :ok ->
            {:ok, {:repaired, confirmed}}

          {:error, reason} ->
            {:error,
             repair_error(
               pr,
               expected_base,
               {:confirmed_head_journal_failed, confirmed_head_sha, reason}
             ), repairing}
        end

      {:error, {:pull_request_base_repair_failed, %{repair_journaled: true}} = reason} ->
        {:error, reason, repairing}

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  defp recover_interrupted_base_repair(target, pr, head_sha, expected_base, opts) do
    case base_repair_invalidation(opts, target) do
      %{repair_state: :repairing} = repairing ->
        persist_recovered_base_repair(target, pr, head_sha, expected_base, repairing, opts)

      %{"repair_state" => "repairing"} = repairing ->
        persist_recovered_base_repair(target, pr, head_sha, expected_base, repairing, opts)

      _ ->
        {:ok, :unchanged}
    end
  end

  defp persist_recovered_base_repair(target, pr, head_sha, expected_base, repairing, opts) do
    recovered = %{
      head_sha: head_sha,
      repaired_at: system_time_seconds(opts),
      repair_state: :repaired
    }

    case journal_base_repair(target, recovered, opts) do
      :ok ->
        {:ok, {:unchanged, recovered}}

      {:error, reason} ->
        {:error,
         repair_error(
           pr,
           expected_base,
           {:repair_confirmation_journal_failed, head_sha, reason}
         ), repairing}
    end
  end

  defp base_repair_invalidation(opts, target) do
    opts
    |> Keyword.get(:base_repair_invalidations, %{})
    |> Map.get(to_string(target))
  end

  defp put_base_repair_invalidation(opts, target, invalidation) do
    invalidations = Keyword.get(opts, :base_repair_invalidations, %{})
    Keyword.put(opts, :base_repair_invalidations, Map.put(invalidations, to_string(target), invalidation))
  end

  defp journal_base_repair(target, invalidation, opts) do
    journal_fun =
      Keyword.get(opts, :base_repair_journal_fun, fn target, marker ->
        CIApprovalStore.journal_base_repair(target, marker)
      end)

    try do
      case journal_fun.(to_string(target), invalidation) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_base_repair_journal_result, other}}
      end
    rescue
      error -> {:error, {:base_repair_journal_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:base_repair_journal_failed, {kind, reason}}}
    end
  end

  defp repair_error(pr, expected_base, reason) do
    {:pull_request_base_repair_failed,
     %{
       pr_number: Map.get(pr, "number"),
       current_base: get_in(pr, ["base", "ref"]),
       expected_base: expected_base,
       reason: reason,
       repair_journaled: true
     }}
  end

  defp base_branch_failure(target, pr_number, head_sha, expected_base, reason, invalidation) do
    excerpt = base_branch_failure_message(pr_number, expected_base, reason)

    Logger.warning("GithubCIPoller rejected pull request base: issue=#{target} reason=#{inspect(reason)}")

    result = %{
      target: target,
      pr_number: pr_number,
      head_sha: head_sha,
      decision: :failed,
      failures: [
        %{
          name: "pull request base branch",
          kind: "pull_request",
          result: "repair_failed",
          excerpt: excerpt
        }
      ]
    }

    if is_map(invalidation),
      do: Map.put(result, :base_repair_invalidation, invalidation),
      else: result
  end

  defp base_branch_repaired(target, pr_number, invalidation, expected_base) do
    Logger.warning(
      "GithubCIPoller repaired pull request base: issue=#{target} pr=#{pr_number} " <>
        "expected_base=#{inspect(expected_base)} action=ci_revalidation_required"
    )

    %{
      target: target,
      pr_number: pr_number,
      head_sha: invalidation.head_sha,
      decision: :failed,
      base_repair_invalidation: invalidation,
      failures: [
        %{
          name: "pull request base branch",
          kind: "pull_request",
          result: "repaired",
          excerpt:
            "Pull request ##{pr_number} was retargeted to configured tracker.base_branch " <>
              "#{inspect(expected_base)}. CI recorded before the repair is not valid for the new base; " <>
              "rerun CI or push a follow-up commit, then verify baseRefName before handoff."
        }
      ]
    }
  end

  defp system_time_seconds(opts) do
    opts
    |> Keyword.get(:system_time_fun, fn -> System.system_time(:second) end)
    |> then(& &1.())
  end

  defp base_branch_failure_message(
         pr_number,
         expected_base,
         {:pull_request_base_repair_failed, details}
       ) do
    "Pull request ##{pr_number} targets #{inspect(details.current_base)}; " <>
      "configured tracker.base_branch is #{inspect(expected_base)}. Automatic REST retarget failed: " <>
      "#{inspect(details.reason)}. Retarget only the PR base, then verify baseRefName before retrying CI."
  end

  defp base_branch_failure_message(pr_number, expected_base, reason) do
    "Pull request ##{pr_number} base could not be verified against configured tracker.base_branch " <>
      "#{inspect(expected_base)}: #{inspect(reason)}. " <>
      "Verify baseRefName or retarget only the PR base before retrying CI."
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_pr_number}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_pr_number}

  defp head_sha(%{"head" => %{"sha" => sha}}) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp head_sha(_pr), do: {:error, :head_sha_missing}

  # REST pull requests and the GraphQL batch both carry draft state (`draft` /
  # `isDraft`); `reviewDecision` is GraphQL-only and stays nil on the REST
  # fallback path. Missing draft state reads false so a never-drafted PR is
  # never misclassified as a stall.
  defp pr_draft?(%{"draft" => draft}) when is_boolean(draft), do: draft
  defp pr_draft?(%{"isDraft" => draft}) when is_boolean(draft), do: draft
  defp pr_draft?(_pr), do: false

  defp poll_error(target, reason) do
    Logger.warning("GithubCIPoller failed: issue=#{target} reason=#{inspect(reason)}")
    %{target: target, decision: :pending, pending_reason: :ci_lookup_unavailable, error: reason}
  end
end
