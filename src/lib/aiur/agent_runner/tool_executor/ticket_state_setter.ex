defmodule Aiur.AgentRunner.ToolExecutor.TicketStateSetter do
  @moduledoc false

  alias Aiur.AgentRunner.{CiWaitTransition, OverrideHandoff, ReworkHandoffGuard}

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
      CiWaitTransition.write(Map.put(coordination, :worker_handoff_receipt, receipt), id, target)
    end
  end

  defp tracker_issue_id(issue) do
    case Map.get(issue, :id) || Map.get(issue, :identifier) do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      _ -> nil
    end
  end
end
