defmodule Aiur.Events.GithubCIPoller.RecoverySafety do
  @moduledoc false
  alias Aiur.GitHub.CIRecovery

  @spec cancelled_checks(map(), String.t(), map()) :: [map()]
  def cancelled_checks(%{checks: checks}, sha, entry) do
    initiated = (entry["cancelled_runs"] || []) |> Enum.filter(&(&1["sha"] == sha)) |> Enum.map(& &1["id"]) |> MapSet.new()
    Enum.reject(checks, &(run_id(&1.url) in initiated))
  end

  @spec recovery_gate(map(), map()) :: :ready | {:held | :skipped, String.t()}
  def recovery_gate(result, pr) do
    cond do
      pr["state"] != "OPEN" or pr["headRefOid"] != result.head_sha -> {:held, "head_changed"}
      pr["isDraft"] == true -> {:skipped, "draft_pr"}
      pr["isDraft"] != false -> {:held, "pr_observation_unavailable"}
      true -> landing_gate(pr)
    end
  end

  defp landing_gate(pr) do
    cond do
      pr["reviewDecision"] == "CHANGES_REQUESTED" -> {:skipped, "changes_requested"}
      not Map.has_key?(pr, "mergeQueueEntry") -> {:held, "queue_observation_unavailable"}
      pr["mergeQueueEntry"] != nil -> {:held, "merge_queue"}
      pr["reviewDecision"] == "APPROVED" and is_map(pr["autoMergeRequest"]) -> {:held, "approved_landing_pr"}
      true -> :ready
    end
  end

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
