defmodule SymphonyElixir.AgentDirectory do
  @moduledoc """
  Read-side MCP-shaped primitives for agents.

  Each function is an atomic read against orchestrator state. A future MCP
  bridge exposes these verbatim as tool surfaces; the in-process pane
  subcommand calls them via `SymphonyElixir.PaneRPC`.

  Scaffold: the function signatures are the public contract. Implementations
  delegate to `SymphonyElixir.Orchestrator.snapshot/0` and the on-disk log
  reader when the agent-list and conversation panes land.
  """

  alias SymphonyElixir.AgentEvents

  @spec list_agents() :: [AgentEvents.agent_summary()]
  def list_agents, do: []

  @spec get_transcript_tail(AgentEvents.agent_identifier(), non_neg_integer()) ::
          [AgentEvents.transcript_event()]
  def get_transcript_tail(identifier, _count) when is_binary(identifier), do: []

  @spec get_alerts(AgentEvents.agent_identifier()) :: [AgentEvents.alert_event()]
  def get_alerts(identifier) when is_binary(identifier), do: []
end
