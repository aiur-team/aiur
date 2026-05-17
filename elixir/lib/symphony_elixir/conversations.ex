defmodule SymphonyElixir.Conversations do
  @moduledoc """
  Agent-native primitive for attaching to an agent's event stream.

  `attach/1` subscribes the caller to the per-agent topic and returns a handle
  that can later be passed to `detach/1`. UI surfaces (the tmux pane subcommand)
  compose this primitive with `SymphonyElixir.Tmux.spawn_pane_for/1`; future
  external consumers (MCP bridge, in-process automation agents) can call
  `attach/1` directly without going through tmux.

  Scaffold: API shape is settled; the implementation lands together with the
  conversation pane in a follow-up session.
  """

  alias SymphonyElixir.{AgentEvents, AgentPubSub}

  @type subscription_ref :: %{identifier: AgentEvents.agent_identifier(), pid: pid()}

  @spec attach(AgentEvents.agent_identifier()) :: {:ok, subscription_ref()} | {:error, term()}
  def attach(identifier) when is_binary(identifier) do
    case AgentPubSub.subscribe_agent(identifier) do
      :ok -> {:ok, %{identifier: identifier, pid: self()}}
      error -> error
    end
  end

  @spec detach(subscription_ref()) :: :ok
  def detach(%{identifier: identifier}) when is_binary(identifier) do
    Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, AgentEvents.agent_topic(identifier))
  end
end
