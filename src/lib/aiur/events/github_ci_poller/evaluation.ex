defmodule Aiur.Events.GithubCIPoller.Evaluation do
  @moduledoc """
  Classifies the check runs and commit statuses `Aiur.Events.GithubCIPoller`
  read for one pull request head.

  Pure: every function takes the observed CI evidence and returns a verdict
  map. It makes no request and writes no state.
  """

  @successful_conclusions ~w(success neutral skipped)
  @failed_statuses ~w(error failure)
  @failed_conclusions ~w(action_required failure startup_failure timed_out)
  @terminal_check_conclusions @successful_conclusions ++ @failed_conclusions

  @doc false
  @spec evaluate([map()], map()) :: map()
  def evaluate(check_runs, commit_status) do
    check_runs =
      check_runs
      |> blocking_check_runs()
      |> latest_check_runs_per_workflow_and_name()

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

  # A skipped draft job satisfies GitHub's check state but never proves the full suite ran.
  @doc false
  @spec enforce_required_checks(map(), [map()], map(), map(), keyword()) :: map()
  def enforce_required_checks(%{decision: :passed} = result, check_runs, commit_status, pr, opts) do
    draft? = Map.get(merge_queue_observation(pr), :draft?, pr_draft?(pr))

    case {draft?, Keyword.fetch!(opts, :required_checks)} do
      {true, _} ->
        Map.merge(result, %{decision: :pending, pending_reason: :draft_pull_request})

      {false, {:ok, required}} ->
        runs = check_runs |> blocking_check_runs() |> latest_check_runs_per_workflow_and_name()
        statuses = Map.get(commit_status, "statuses", [])

        if Enum.all?(required, &required_check_passed?(&1, runs, statuses)) do
          result
        else
          Map.merge(result, %{decision: :pending, pending_reason: :required_checks_incomplete})
        end

      {false, {:error, reason}} ->
        Map.merge(result, %{decision: :pending, pending_reason: :required_checks_unavailable, error: reason})
    end
  end

  def enforce_required_checks(result, _runs, _statuses, _pr, _opts), do: result

  defp required_check_passed?(%{name: name, app_id: app_id}, runs, statuses) do
    Enum.any?(runs, fn run ->
      Map.get(run, "name") == name and Map.get(run, "status") == "completed" and
        Map.get(run, "conclusion") in ~w(success neutral) and
        (app_id in [nil, -1] or get_in(run, ["app", "id"]) == app_id)
    end) or
      (app_id in [nil, -1] and Enum.any?(statuses, &(Map.get(&1, "context") == name and Map.get(&1, "state") == "success")))
  end

  # Carries the batch's merge-queue recovery observation (ready/approved/
  # mergeable/armed/queued) into the poll result so CiLifecycle can alert on a
  # parked-ready PR. Absent on the REST fallback path and on error/no-PR
  # results; CiLifecycle treats a missing observation as `:unknown` (fail
  # closed) instead of arming or clearing a recovery signal on partial data.
  @doc false
  @spec merge_queue_observation(map()) :: map()
  def merge_queue_observation(%{} = pr) do
    case Map.get(pr, "merge_queue") do
      %{} = observation when map_size(observation) > 0 -> observation
      _other -> %{}
    end
  end

  # REST pull requests and the GraphQL batch both carry draft state (`draft` /
  # `isDraft`); `reviewDecision` is GraphQL-only and stays nil on the REST
  # fallback path. Missing draft state reads false so a never-drafted PR is
  # never misclassified as a stall.
  @doc false
  @spec pr_draft?(term()) :: boolean()
  def pr_draft?(%{"draft" => draft}) when is_boolean(draft), do: draft
  def pr_draft?(%{"isDraft" => draft}) when is_boolean(draft), do: draft
  def pr_draft?(_pr), do: false

  # A head sha can carry check runs from several runs of the same workflow when
  # a run was superseded by a re-run on the same sha. A superseded run's
  # failure is not a failure of the head — the current run is the verdict — so
  # the gate considers only the latest run per (workflow, name) (#2337 cause 4).
  #
  # The workflow scope is `check_suite.id`: GitHub re-runs of the same workflow
  # reuse the suite id, while different workflows (ci, website, streamdeck,
  # netlify…) each own a distinct suite. Keying on name alone would collapse a
  # same-named job across workflows — ci.yml's `build` and
  # streamdeck-package.yml's `build` land on one head sha, and a failing
  # required `build` could be dropped by a later-starting green one from the
  # other workflow. Scoping by suite keeps that impossible (#2346 review).
  # `started_at` is the recency key (falls back to `completed_at`); ISO8601
  # strings compare chronologically. Output preserves each key's first-seen
  # position so downstream failure lists keep their input order. A run with no
  # suite identity is scoped by its own id, so it is never collapsed with any
  # other run — failing toward not dropping a failure.
  defp latest_check_runs_per_workflow_and_name(check_runs) do
    {latest, ordered_keys} =
      Enum.reduce(check_runs, {%{}, []}, fn run, {latest, ordered_keys} ->
        key = {check_run_workflow(run), Map.get(run, "name")}

        case Map.fetch(latest, key) do
          {:ok, current} ->
            {put_latest_check_run(latest, key, run, current), ordered_keys}

          :error ->
            {Map.put(latest, key, run), ordered_keys ++ [key]}
        end
      end)

    Enum.map(ordered_keys, &Map.fetch!(latest, &1))
  end

  # Keeps the newer run for a key when both a superseded and the current run of
  # the same workflow reported on the head sha.
  defp put_latest_check_run(latest, key, run, current) do
    updated = if check_run_recency_key(run) >= check_run_recency_key(current), do: run, else: current
    Map.put(latest, key, updated)
  end

  # The check suite id identifies the workflow run a check run belongs to. It
  # arrives flat (`"check_suite_id"`) from the GraphQL batch and webhook
  # normalizers and nested (`["check_suite"]["id"]`) from the raw REST
  # check-runs read. Absent either, the run's own id scopes it so same-named
  # suite-less runs are never collapsed together.
  defp check_run_workflow(check_run) do
    case Map.get(check_run, "check_suite_id") || get_in(check_run, ["check_suite", "id"]) do
      id when not is_nil(id) -> {:suite, id}
      _other -> {:run, Map.get(check_run, "id")}
    end
  end

  defp check_run_recency_key(check_run) do
    Map.get(check_run, "started_at") || Map.get(check_run, "completed_at") || ""
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

  @doc false
  @spec enforce_base_repair_invalidation(map(), term(), String.t(), [map()], map(), keyword()) :: map()
  def enforce_base_repair_invalidation(result, target, head_sha, check_runs, commit_status, opts) do
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
end
