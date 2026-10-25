defmodule Aiur.AgentRunner.ToolExecutor.TicketStateSetter do
  @moduledoc false

  alias Aiur.AgentRunner.{CiWaitTransition, ReworkHandoffGuard}

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
        coordination.run.(
          coordination_key.(issue),
          fn ->
            ReworkHandoffGuard.write(issue, issue_id, state, workspace, worker_host, opts, &CiWaitTransition.write(coordination, &1, &2))
          end,
          operation_opts.(issue)
        )
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
