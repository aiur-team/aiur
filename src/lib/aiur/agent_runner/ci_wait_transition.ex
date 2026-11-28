defmodule Aiur.AgentRunner.CiWaitTransition do
  @moduledoc false

  alias Aiur.{Commands, Orchestrator.ReworkGate}

  @spec write(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def write(coordination, issue_id, state_name) do
    with {:ok, draft_handoff} <- verify_pr(coordination, issue_id, state_name),
         :ok <- validate_outcome_handoff(coordination, state_name),
         :ok <- coordination.set_ticket_state.(issue_id, state_name) do
      {:ok, Map.merge(%{state: state_name, issue: issue_id}, draft_handoff)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp validate_outcome_handoff(_coordination, state_name) when state_name != "human-review", do: :ok

  defp validate_outcome_handoff(coordination, _state_name) do
    labels = Map.get(coordination, :outcome_gate_labels, [])

    if Enum.any?(labels, &(&1 in ["creator-facing", "engineering-only"])) do
      decisions_fun = Map.get(coordination, :outcome_decisions_fun, &Commands.list_decisions/0)

      try do
        case Commands.validate_review_handoff(labels, Map.get(coordination, :outcome_gate_identifier), decisions_fun.()) do
          :ok -> :ok
          {:error, reason} -> {:error, {:creator_review_gate, reason}}
        end
      rescue
        _error -> {:error, {:creator_review_gate, :outcome_evidence_unavailable}}
      catch
        :exit, _reason -> {:error, {:creator_review_gate, :outcome_evidence_unavailable}}
      end
    else
      :ok
    end
  end

  defp verify_pr(_coordination, _issue_id, state_name) when state_name not in ["ci-wait", "human-review"], do: {:ok, %{}}

  defp verify_pr(coordination, issue_id, state_name) do
    if Aiur.CodeHost.available?() do
      case coordination.ci_wait_pr_fetcher.(issue_id) do
        {:ok, %{"draft" => true, "number" => number} = pr} -> verify_draft(coordination, pr, number, state_name)
        # #8102: ci-wait only wakes on CI events, which never come without a PR carrying the local work.
        {:ok, nil} when state_name == "ci-wait" -> unpublished("there is no open pull request for this ticket")
        {:ok, pr} when state_name == "ci-wait" -> published_receipt(coordination, pr)
        {:ok, pr_or_missing} -> receipt(coordination, pr_or_missing, %{})
        {:error, _reason} -> {:ok, %{}}
        _other -> {:ok, %{}}
      end
    else
      receipt(coordination, nil, %{})
    end
  end

  defp published_receipt(coordination, pr) do
    case verify_published(coordination, pr) do
      :ok -> receipt(coordination, pr, %{})
      refused -> refused
    end
  end

  # Only a local checkout root is inspected; a remote worker's path or an unreadable checkout fails open.
  defp verify_published(%{handoff_workspace: workspace}, pr) when is_binary(workspace) do
    with true <- File.exists?(Path.join(workspace, ".git")),
         {status, 0} <- System.cmd("git", ["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true),
         {head, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      head = String.trim(head)
      pr_head = ReworkGate.head_sha(pr)

      cond do
        String.trim(status) != "" -> unpublished("the workspace has uncommitted or untracked changes")
        is_binary(pr_head) and String.downcase(pr_head) != String.downcase(head) -> unpublished("local HEAD #{head} is not the PR head #{pr_head}")
        true -> :ok
      end
    else
      _ -> :ok
    end
  end

  defp verify_published(_coordination, _pr), do: :ok

  defp unpublished(why) do
    {:error,
     {:ci_wait_work_unpublished,
      "Cannot move this ticket to ci-wait: #{why}. CI never runs on unpublished work. Commit, push and open the PR " <>
        "(`gh pr create --base \"$AIUR_BASE_BRANCH\"`), mark it ready, then hand off again."}}
  end

  # A draft may reach a reviewer only when something outside the ticket keeps
  # it from being ready and the worker says what. It never enters ci-wait.
  defp verify_draft(coordination, pr, number, "human-review") do
    case outside_blocker(coordination) do
      nil -> {:error, {:draft_pr_cannot_enter_state, "human-review", number}}
      reason -> receipt(coordination, pr, %{draft_pull_request: number, outside_blocker: reason})
    end
  end

  defp verify_draft(_coordination, _pr, number, state_name), do: {:error, {:draft_pr_cannot_enter_state, state_name, number}}

  defp outside_blocker(coordination) do
    case Map.get(coordination, :outside_blocker) do
      reason when is_binary(reason) -> if String.trim(reason) == "", do: nil, else: String.trim(reason)
      _ -> nil
    end
  end

  defp receipt(coordination, pr, draft_handoff) do
    result =
      case Map.get(coordination, :worker_handoff_receipt) do
        callback when is_function(callback, 1) -> callback.(pr)
        _ -> :ok
      end

    case result do
      :ok -> {:ok, draft_handoff}
      other -> other
    end
  end
end
