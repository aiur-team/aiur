defmodule Aiur.Events.GithubCIPoller do
  @moduledoc """
  Polls GitHub CI state for the current head of canonical Aiur pull requests.

  GitHub publishes modern check runs and legacy commit statuses through
  separate APIs. This module reads both for each current PR head, classifies the
  aggregate conservatively, and leaves label changes plus event publication to
  the orchestrator.
  """

  require Logger

  alias Aiur.GitHub.Client

  @type target :: String.t() | integer()
  @type decision :: :pending | :passed | :failed | :test_failed

  @successful_conclusions ~w(success neutral skipped)
  @failed_statuses ~w(error failure)
  @failed_conclusions ~w(action_required cancelled failure stale startup_failure timed_out)
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

  defp poll_open_pull_request(target, pr, opts) do
    with {:ok, pr_number} <- positive_integer(Map.get(pr, "number")),
         {:ok, head_sha} <- head_sha(pr),
         {:ok, %{check_runs: check_runs, commit_status: commit_status}} <-
           Client.fetch_commit_ci_status(head_sha, opts) do
      poll_current_head_result(target, pr_number, head_sha, check_runs, commit_status, opts)
    else
      {:error, reason} -> poll_error(target, reason)
    end
  end

  defp poll_current_head_result(target, pr_number, observed_head_sha, check_runs, commit_status, opts) do
    case Client.fetch_open_pull_request_for_branch(target, opts) do
      {:ok, current_pr} when is_map(current_pr) ->
        case head_sha(current_pr) do
          {:ok, ^observed_head_sha} ->
            evaluate(check_runs, commit_status)
            |> Map.merge(%{target: target, pr_number: pr_number, head_sha: observed_head_sha})

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

      {:ok, nil} ->
        %{target: target, decision: :pending, pending_reason: :open_pr_no_longer_visible}

      {:error, reason} ->
        poll_error(target, {:pr_recheck, reason})
    end
  end

  defp evaluate(check_runs, commit_status) do
    check_runs = Enum.filter(check_runs, &is_map/1)
    statuses = commit_status |> Map.get("statuses", []) |> Enum.filter(&is_map/1)
    failed_checks = failed_check_runs(check_runs) ++ failed_commit_statuses(statuses)

    failed_checks =
      if failed_checks == [] do
        failed_combined_status(commit_status)
      else
        failed_checks
      end

    decision =
      cond do
        failed_checks != [] -> failure_decision(failed_checks)
        incomplete_check_runs?(check_runs) -> :pending
        incomplete_commit_statuses?(statuses) -> :pending
        incomplete_combined_status?(commit_status) -> :pending
        observed_ci_signal?(check_runs, statuses, commit_status) -> :passed
        true -> :pending
      end

    %{decision: decision, failures: failed_checks}
  end

  defp failure_decision(failures) do
    if Enum.all?(failures, &test_failure?/1), do: :test_failed, else: :failed
  end

  defp test_failure?(%{name: "test"}), do: true
  defp test_failure?(_failure), do: false

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

      status != "completed" or conclusion not in @successful_conclusions
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
