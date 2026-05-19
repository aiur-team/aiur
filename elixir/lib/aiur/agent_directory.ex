defmodule Aiur.AgentDirectory do
  @moduledoc """
  Read-side MCP-shaped primitives for agents.

  Each function is an atomic read against orchestrator state. A future MCP
  bridge exposes these verbatim as tool surfaces; the in-process pane
  subcommand calls them via `Aiur.PaneRPC`.

  Scaffold: the function signatures are the public contract. Implementations
  delegate to `Aiur.Orchestrator.snapshot/0` and the on-disk log
  reader when the agent-list and conversation panes land.
  """

  alias Aiur.AgentEvents

  @spec list_agents() :: [AgentEvents.agent_summary()]
  def list_agents do
    case Aiur.Orchestrator.snapshot() do
      %{running: running} when is_list(running) ->
        Enum.map(running, fn entry ->
          AgentEvents.agent_summary(Map.get(entry, :identifier, ""), :running, 0, %{
            tag: Map.get(entry, :tag),
            title: Map.get(entry, :title),
            runtime_seconds: Map.get(entry, :runtime_seconds),
            turn_count: Map.get(entry, :turn_count),
            work_state: Map.get(entry, :work_state) || :working
          })
        end)
        |> Enum.reject(fn %{identifier: identifier} -> identifier == "" end)

      _ ->
        []
    end
  end

  @spec get_transcript_tail(AgentEvents.agent_identifier(), non_neg_integer()) ::
          [AgentEvents.transcript_event()]
  def get_transcript_tail(identifier, _count) when is_binary(identifier), do: []

  @spec get_alerts(AgentEvents.agent_identifier()) :: [AgentEvents.alert_event()]
  def get_alerts(identifier) when is_binary(identifier), do: []
end
