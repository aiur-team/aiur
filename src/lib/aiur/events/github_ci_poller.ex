defmodule Aiur.Events.GithubCIPoller do
  @moduledoc """
  Polls GitHub CI state for the current head of canonical Aiur pull requests.

  GitHub publishes modern check runs and legacy commit statuses through
  separate APIs. This module reads both for each current PR head, classifies the
  aggregate conservatively, and leaves label changes plus event publication to
  the orchestrator.
  """

  require Logger

  alias Aiur.Events.GithubCIPoller.{BaseRepair, Evaluation}
  alias Aiur.GitHub.{CiReadiness, Client}
  alias Aiur.Stacking.StackBaseEvidence

  @type target :: String.t() | integer()
  @type decision :: :pending | :passed | :failed

  @default_max_concurrency 4
  @default_target_timeout 60_000

  @spec poll([target()], keyword()) :: {:ok, %{results: [map()], errors: [{String.t(), term()}]}}
  def poll(targets, opts \\ []) when is_list(targets) do
    targets = normalize_targets(targets)

    required_check_fetcher = Keyword.get(opts, :required_check_fetcher, &CiReadiness.fetch_required_checks/1)
    required_checks = if targets == [], do: {:ok, []}, else: required_check_fetcher.(opts)
    opts = Keyword.put(opts, :required_checks, required_checks)

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
    Evaluation.evaluate(check_runs, commit_status)
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
      expected_base = StackBaseEvidence.expected_base(target, pr, opts)

      case BaseRepair.ensure_pull_request_base(target, pr, head_sha, expected_base, opts) do
        {:ok, :unchanged} ->
          Evaluation.evaluate(check_runs, commit_status)
          |> Evaluation.enforce_required_checks(check_runs, commit_status, pr, opts)
          |> Evaluation.enforce_base_repair_invalidation(target, head_sha, check_runs, commit_status, opts)
          |> Map.merge(%{target: target, pr_number: pr_number, head_sha: head_sha})
          |> Map.merge(Evaluation.merge_queue_observation(pr))
          |> log_classification()

        {:ok, {:unchanged, recovered_invalidation}} ->
          Evaluation.evaluate(check_runs, commit_status)
          |> Evaluation.enforce_required_checks(check_runs, commit_status, pr, opts)
          |> Evaluation.enforce_base_repair_invalidation(target, head_sha, check_runs, commit_status, opts)
          |> Map.merge(%{target: target, pr_number: pr_number, head_sha: head_sha, base_repair_invalidation: recovered_invalidation})
          |> Map.merge(Evaluation.merge_queue_observation(pr))
          |> log_classification()

        {:ok, {:repaired, invalidation}} ->
          BaseRepair.base_branch_repaired(target, pr_number, invalidation, expected_base)

        {:error, reason, invalidation} ->
          BaseRepair.base_branch_failure(target, pr_number, head_sha, expected_base, reason, invalidation)
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

  defp poll_open_pull_request(target, pr, opts) do
    with {:ok, pr_number} <- positive_integer(Map.get(pr, "number")),
         {:ok, head_sha} <- head_sha(pr) do
      expected_base = StackBaseEvidence.expected_base(target, pr, opts)

      case BaseRepair.ensure_pull_request_base(target, pr, head_sha, expected_base, opts) do
        {:ok, :unchanged} ->
          poll_open_pull_request_ci(target, pr_number, head_sha, opts)

        {:ok, {:unchanged, recovered_invalidation}} ->
          opts = BaseRepair.put_base_repair_invalidation(opts, target, recovered_invalidation)

          target
          |> poll_open_pull_request_ci(pr_number, head_sha, opts)
          |> Map.put(:base_repair_invalidation, recovered_invalidation)

        {:ok, {:repaired, invalidation}} ->
          BaseRepair.base_branch_repaired(target, pr_number, invalidation, expected_base)

        {:error, reason, invalidation} ->
          BaseRepair.base_branch_failure(target, pr_number, head_sha, expected_base, reason, invalidation)
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
    expected_base = StackBaseEvidence.expected_base(target, current_pr, opts)

    case head_sha(current_pr) do
      {:ok, current_head_sha} ->
        case BaseRepair.ensure_pull_request_base(target, current_pr, current_head_sha, expected_base, opts) do
          {:ok, :unchanged} ->
            current_head_result(target, pr_number, current_pr, observed_head_sha, check_runs, commit_status, opts)

          {:ok, {:unchanged, recovered_invalidation}} ->
            opts = BaseRepair.put_base_repair_invalidation(opts, target, recovered_invalidation)

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
            BaseRepair.base_branch_repaired(target, pr_number, invalidation, expected_base)

          {:error, reason, invalidation} ->
            BaseRepair.base_branch_failure(
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
        Evaluation.evaluate(check_runs, commit_status)
        |> Evaluation.enforce_required_checks(check_runs, commit_status, current_pr, opts)
        |> Evaluation.enforce_base_repair_invalidation(target, observed_head_sha, check_runs, commit_status, opts)
        |> Map.merge(%{
          target: target,
          pr_number: pr_number,
          head_sha: observed_head_sha,
          draft?: Evaluation.pr_draft?(current_pr),
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

  defp poll_error(target, reason) do
    Logger.warning("GithubCIPoller failed: issue=#{target} reason=#{inspect(reason)}")
    %{target: target, decision: :pending, pending_reason: :ci_lookup_unavailable, error: reason}
  end
end
