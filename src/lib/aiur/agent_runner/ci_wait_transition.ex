defmodule Aiur.AgentRunner.CiWaitTransition do
  @moduledoc false

  @spec write(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def write(coordination, issue_id, state_name) do
    with :ok <- verify_pr(coordination, issue_id, state_name),
         :ok <- coordination.set_ticket_state.(issue_id, state_name) do
      {:ok, %{state: state_name, issue: issue_id}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp verify_pr(_coordination, _issue_id, state_name) when state_name not in ["ci-wait", "human-review"], do: :ok

  defp verify_pr(coordination, issue_id, state_name) do
    if Aiur.CodeHost.available?() do
      case coordination.ci_wait_pr_fetcher.(issue_id) do
        {:ok, %{"draft" => true, "number" => number}} -> {:error, {:draft_pr_cannot_enter_state, state_name, number}}
        {:ok, _pr_or_missing} -> :ok
        {:error, _reason} -> :ok
        _other -> :ok
      end
    else
      :ok
    end
  end
end
