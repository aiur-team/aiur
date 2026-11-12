defmodule Aiur.AgentRunner.CiWaitTransition do
  @moduledoc false

  @spec write(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def write(coordination, issue_id, state_name) do
    with {:ok, draft_handoff} <- verify_pr(coordination, issue_id, state_name),
         :ok <- coordination.set_ticket_state.(issue_id, state_name) do
      {:ok, Map.merge(%{state: state_name, issue: issue_id}, draft_handoff)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp verify_pr(_coordination, _issue_id, state_name) when state_name not in ["ci-wait", "human-review"], do: {:ok, %{}}

  defp verify_pr(coordination, issue_id, state_name) do
    if Aiur.CodeHost.available?() do
      case coordination.ci_wait_pr_fetcher.(issue_id) do
        {:ok, %{"draft" => true, "number" => number} = pr} -> verify_draft(coordination, pr, number, state_name)
        {:ok, pr_or_missing} -> receipt(coordination, pr_or_missing, %{})
        {:error, _reason} -> {:ok, %{}}
        _other -> {:ok, %{}}
      end
    else
      receipt(coordination, nil, %{})
    end
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
