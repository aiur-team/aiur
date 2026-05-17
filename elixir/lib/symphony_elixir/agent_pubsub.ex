defmodule SymphonyElixir.AgentPubSub do
  @moduledoc """
  Thin Phoenix.PubSub wrapper for agent events.

  Subscribes and broadcasts on the topics defined in `SymphonyElixir.AgentEvents`.
  Modeled on `SymphonyElixirWeb.ObservabilityPubSub`: a single source of truth
  for the agent-side topic vocabulary, plus a defensive `Process.whereis` guard
  so producers do not crash when PubSub is not yet started (early boot or test
  contexts).
  """

  alias SymphonyElixir.AgentEvents

  @pubsub SymphonyElixir.PubSub

  @spec subscribe_agent(AgentEvents.agent_identifier()) :: :ok | {:error, term()}
  def subscribe_agent(identifier) when is_binary(identifier) do
    Phoenix.PubSub.subscribe(@pubsub, AgentEvents.agent_topic(identifier))
  end

  @spec subscribe_running() :: :ok | {:error, term()}
  def subscribe_running, do: Phoenix.PubSub.subscribe(@pubsub, AgentEvents.running_topic())

  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(@pubsub, AgentEvents.status_topic())

  @spec broadcast_transcript(AgentEvents.agent_identifier(), AgentEvents.transcript_event()) :: :ok
  def broadcast_transcript(identifier, %{role: _, body: _, timestamp: _} = event)
      when is_binary(identifier) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:transcript_event, event})
  end

  @spec broadcast_alert(AgentEvents.agent_identifier(), AgentEvents.alert_event()) :: :ok
  def broadcast_alert(identifier, %{name: _, message: _, timestamp: _} = event)
      when is_binary(identifier) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:alert, event})
  end

  @spec broadcast_running_change([AgentEvents.agent_summary()]) :: :ok
  def broadcast_running_change(summaries) when is_list(summaries) do
    do_broadcast(AgentEvents.running_topic(), {:running_changed, summaries})
  end

  @spec broadcast_status_change(AgentEvents.agent_identifier(), atom()) :: :ok
  def broadcast_status_change(identifier, status) when is_binary(identifier) and is_atom(status) do
    do_broadcast(AgentEvents.status_topic(), {:status_changed, %{identifier: identifier, status: status}})
  end

  defp do_broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.broadcast(@pubsub, topic, message)
      _ -> :ok
    end
  end
end
