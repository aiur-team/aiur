defmodule Aiur.AgentRunner.ToolExecutor.TicketStateSetter do
  @moduledoc false

  alias Aiur.AgentRunner.{CiWaitTransition, OverrideHandoff, ReworkHandoffGuard, TurnAlerts}

  @spec write(
          Aiur.Issue.t(),
          term(),
          map(),
          Path.t() | nil,
          String.t() | nil,
          keyword(),
          (Aiur.Issue.t() -> term()),
          (Aiur.Issue.t() -> keyword())
        ) :: term()
  def write(issue, state, coordination, workspace, worker_host, opts, coordination_key, operation_opts) do
    case tracker_issue_id(issue) do
      nil ->
        {:error, :no_issue_number}

      issue_id ->
        writer = state_writer(issue.identifier, coordination, workspace, worker_host, opts)

        coordination.run.(
          coordination_key.(issue),
          fn ->
            ReworkHandoffGuard.write(issue, issue_id, state, workspace, worker_host, opts, writer)
          end,
          operation_opts.(issue)
        )
    end
  end

  defp state_writer(identifier, coordination, workspace, worker_host, opts) do
    recorder = Keyword.get(opts, :override_handoff_recorder, &OverrideHandoff.record/6)

    fn id, target ->
      receipt = fn pr -> recorder.(identifier, target, pr, workspace, worker_host, opts) end

      coordination
      |> Map.put(:worker_handoff_receipt, receipt)
      |> Map.put(:outside_blocker, Keyword.get(opts, :outside_blocker))
      |> CiWaitTransition.write(id, target)
      |> tap(&alert_draft_handoff(&1, identifier, workspace, worker_host))
    end
  end

  defp alert_draft_handoff({:ok, %{draft_pull_request: number, outside_blocker: reason}}, identifier, workspace, worker_host),
    do: TurnAlerts.emit_draft_handoff_alert(identifier, number, reason, workspace, worker_host)

  defp alert_draft_handoff(_result, _identifier, _workspace, _worker_host), do: :ok

  defp tracker_issue_id(issue) do
    case Map.get(issue, :id) || Map.get(issue, :identifier) do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      _ -> nil
    end
  end
end
