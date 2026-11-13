defmodule Aiur.ControlCLI.Blocker do
  @moduledoc false

  alias Aiur.AgentRunner.DeclaredBlockers
  import Aiur.ControlCLI.Protocol, only: [control_error: 1, exit_marker: 1, guarded: 2]

  @doc "`aiur blocker confirm|dismiss <ticket> <blocker>`: the Executor's verdict on a worker-declared blocker."
  @spec run(keyword()) :: :ok
  def run(opts) do
    {action, ticket, blocker} = {Keyword.fetch!(opts, :action), Keyword.fetch!(opts, :ticket), Keyword.fetch!(opts, :blocker)}

    guarded("blocker #{action}", fn -> ticket |> DeclaredBlockers.set_verdict(blocker, action) |> report(action, ticket, blocker) end)
  end

  defp report(:ok, action, ticket, blocker) do
    if action == :confirm, do: request_dependency_pause(ticket, blocker)
    IO.puts(success(action, ticket, blocker))
    exit_marker(0)
  end

  defp report({:error, :not_declared}, _action, ticket, blocker) do
    control_error("aiur: ##{ticket} has no worker-declared blocker ##{blocker}")
    exit_marker(1)
  end

  defp report({:error, reason}, action, _ticket, _blocker) do
    control_error("aiur: blocker #{action} failed: #{inspect(reason)}")
    exit_marker(1)
  end

  # Routed like the worker's own dependency pause request, which now pauses because the link is confirmed.
  defp request_dependency_pause(ticket, blocker) do
    case GenServer.whereis(Aiur.Project.whereis(Aiur.Orchestrator)) do
      pid when is_pid(pid) ->
        send(pid, {:event, %{topic: "ticket.#{ticket}.agent.pause.request", payload: %{reason: "dependency", blocker_identifier: blocker}}})

      _ ->
        :ok
    end
  end

  defp success(:confirm, ticket, blocker), do: "##{ticket} holds until ##{blocker} merges; a running worker is paused"
  defp success(:dismiss, ticket, blocker), do: "##{blocker} stays advisory for ##{ticket}"
end
