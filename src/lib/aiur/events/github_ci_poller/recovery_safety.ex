defmodule Aiur.Events.GithubCIPoller.RecoverySafety do
  @moduledoc false
  alias Aiur.GitHub.CIRecovery
  alias Aiur.Signal

  # A head's AI-cancelled runs are its only CI when the ticket is approved without
  # a new push, so recovery reruns them instead of skipping them (#7562).
  @spec approved_cancelled?(map()) :: boolean()
  def approved_cancelled?(%{pending_reason: :ci_cancelled, review_decision: "APPROVED"}), do: true
  def approved_cancelled?(_result), do: false

  @spec rerun_checks(map(), map(), map()) :: [map()]
  def rerun_checks(result, %{checks: checks} = digest, entry) do
    sha = result[:head_sha]

    case approved_cancelled?(result) and Enum.filter(checks, &(run_id(&1.url) in initiated_ids(entry, sha))) do
      [_ | _] = rework_cancelled -> rework_cancelled
      _ -> cancelled_checks(digest, sha, entry)
    end
  end

  @spec cancelled_checks(map(), String.t(), map()) :: [map()]
  def cancelled_checks(%{checks: checks}, sha, entry) do
    initiated = initiated_ids(entry, sha)
    Enum.reject(checks, &(run_id(&1.url) in initiated))
  end

  # An approved head gets no further push, so its recovery rerun is the operator's
  # only visible sign that the rework cancel was undone; journal it as an event.
  @spec record_rerun(map(), map(), [map()], keyword()) :: :ok
  def record_rerun(issue, result, runs, opts) do
    if approved_cancelled?(result) do
      message = "CI recovery reran the cancelled CI (#{Enum.map_join(runs, ", ", &"##{&1["id"]}")}) on approved head #{result[:head_sha]} for PR ##{result[:pr_number]}."
      emitter = Keyword.get(opts, :alert_emitter, &Signal.alert/2)
      _ = emitter.("ticket.#{issue.identifier || issue.id}.pr.ci_recovery.rerun", issue: issue, central: true, needs_attention: false, message: message, reason: "approved_head_rework_cancelled_ci")
    end

    :ok
  end

  defp initiated_ids(entry, sha) do
    (entry["cancelled_runs"] || []) |> Enum.filter(&(&1["sha"] == sha)) |> Enum.map(& &1["id"]) |> MapSet.new()
  end

  @spec recovery_gate(map(), map(), map()) :: :ready | {:held | :skipped, String.t()}
  def recovery_gate(result, pr, entry) do
    cond do
      pr["state"] != "OPEN" or pr["headRefOid"] != result.head_sha -> {:held, "head_changed"}
      pr["isDraft"] == true -> {:skipped, "draft_pr"}
      pr["isDraft"] != false -> {:held, "pr_observation_unavailable"}
      true -> landing_gate(result, pr, entry)
    end
  end

  defp landing_gate(result, pr, entry) do
    cond do
      pr["reviewDecision"] == "CHANGES_REQUESTED" -> {:skipped, "changes_requested"}
      not Map.has_key?(pr, "mergeQueueEntry") -> {:held, "queue_observation_unavailable"}
      pr["mergeQueueEntry"] != nil -> {:held, "merge_queue"}
      approved_landing?(result, pr, entry) -> {:held, "approved_landing_pr"}
      true -> :ready
    end
  end

  defp approved_landing?(result, %{"reviewDecision" => "APPROVED", "autoMergeRequest" => request}, entry),
    do: is_map(request) and not rework_cancelled_rerun?(result, entry)

  defp approved_landing?(_result, _pr, _entry), do: false

  # An approved head whose only CI Aiur cancelled for rework gets one bounded rerun
  # instead of the approved-landing hold; a person cancel keeps the hold.
  defp rework_cancelled_rerun?(%{pending_reason: :ci_cancelled, head_sha: sha} = result, entry) when is_binary(sha),
    do: approved_cancelled?(result) and Enum.any?(List.wrap(result[:failures]), &(run_id(&1[:url]) in initiated_ids(entry, sha)))

  defp rework_cancelled_rerun?(_result, _entry), do: false

  @spec failed_current_run(integer(), String.t(), keyword()) :: {:ok, map()} | :superseded | {:error, term()}
  def failed_current_run(id, sha, opts) do
    case CIRecovery.read("/actions/runs/#{id}", opts) do
      {:ok, %{"head_sha" => ^sha, "run_attempt" => attempt, "status" => "completed", "conclusion" => conclusion, "name" => _name} = run}
      when is_integer(attempt) and conclusion in ["failure", "timed_out", "cancelled"] ->
        case newer_workflow_run?(run, id, attempt, sha, opts) do
          {:ok, true} -> :superseded
          {:ok, false} -> {:ok, %{"id" => id, "attempt" => attempt, "conclusion" => conclusion}}
          {:error, reason} -> {:error, reason}
        end

      other ->
        {:error, {:invalid_actions_run, id, other}}
    end
  end

  defp newer_workflow_run?(run, id, attempt, sha, opts) do
    case CIRecovery.read("/actions/runs?head_sha=#{sha}&event=pull_request&per_page=100", opts) do
      {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
        {:ok, Enum.any?(runs, &newer_run_for_workflow?(&1, run["name"], id, attempt, sha))}

      {:ok, _} ->
        {:error, :invalid_actions_runs_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp newer_run_for_workflow?(candidate, name, id, attempt, sha) do
    candidate["head_sha"] == sha and candidate["name"] == name and is_integer(candidate["id"]) and
      (candidate["id"] > id or (candidate["id"] == id and is_integer(candidate["run_attempt"]) and candidate["run_attempt"] > attempt))
  end

  @spec failing_runs([map()], String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def failing_runs(checks, sha, opts) do
    ids = checks |> Enum.map(&run_id(&1.url)) |> Enum.uniq()

    if ids == [] or nil in ids do
      {:error, :missing_actions_run_identity}
    else
      Enum.reduce_while(ids, {:ok, []}, &collect_failed_run(&1, &2, sha, opts))
    end
  end

  defp collect_failed_run(id, {:ok, runs}, sha, opts) do
    case failed_current_run(id, sha, opts) do
      {:ok, run} -> {:cont, {:ok, runs ++ [run]}}
      :superseded -> {:cont, {:ok, runs}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec run_id(term()) :: integer() | nil
  def run_id(url) when is_binary(url) do
    case Regex.run(~r{/actions/runs/(\d+)(?:/|$)}, url) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  def run_id(_), do: nil
end
