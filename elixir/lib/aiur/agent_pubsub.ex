defmodule Aiur.AgentPubSub do
  @moduledoc """
  Thin Phoenix.PubSub wrapper for agent events.

  Subscribes and broadcasts on the topics defined in `Aiur.AgentEvents`.
  Modeled on `AiurWeb.ObservabilityPubSub`: a single source of truth
  for the agent-side topic vocabulary, plus a defensive `Process.whereis` guard
  so producers do not crash when PubSub is not yet started (early boot or test
  contexts).
  """

  require Logger

  alias Aiur.AgentEvents

  @pubsub Aiur.PubSub

  @spec subscribe_agent(AgentEvents.agent_identifier()) :: :ok | {:error, term()}
  def subscribe_agent(identifier) when is_binary(identifier) do
    topic = AgentEvents.agent_topic(identifier)
    result = Phoenix.PubSub.subscribe(@pubsub, topic)
    Logger.debug("AgentPubSub.subscribe_agent topic=#{topic} pid=#{inspect(self())} result=#{inspect(result)}")
    result
  end

  @spec subscribe_running() :: :ok | {:error, term()}
  def subscribe_running, do: Phoenix.PubSub.subscribe(@pubsub, AgentEvents.running_topic())

  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(@pubsub, AgentEvents.status_topic())

  @spec subscribe_poll_state() :: :ok | {:error, term()}
  def subscribe_poll_state,
    do: Phoenix.PubSub.subscribe(@pubsub, AgentEvents.poll_state_topic())

  @doc """
  Broadcast the orchestrator's polling state.

  `checking?` is true while the orchestrator is mid-dispatch (fetching
  candidate issues, syncing tracker state, etc.). `next_poll_due_at_ms`
  is an absolute `System.system_time(:millisecond)` timestamp when the
  next poll cycle will begin, or `nil` while a cycle is in progress.

  AgentList consumes this so its 1 Hz countdown render does NOT need to
  GenServer.call into the orchestrator on every tick — that call was
  blocking the agent-list mailbox for several seconds during each poll
  cycle, freezing arrow keys until the cycle completed.
  """
  @spec broadcast_poll_state(%{
          checking?: boolean(),
          next_poll_due_at_ms: integer() | nil
        }) :: :ok
  def broadcast_poll_state(%{checking?: _, next_poll_due_at_ms: _} = payload) do
    do_broadcast(AgentEvents.poll_state_topic(), {:poll_state_changed, payload})
  end

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

  @spec broadcast_turn_event(AgentEvents.agent_identifier(), atom(), map()) :: :ok
  def broadcast_turn_event(identifier, event_tag, payload)
      when is_binary(identifier) and event_tag in [:turn_completed, :turn_failed, :turn_cancelled, :turn_input_required] and
             is_map(payload) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:turn_event, identifier, event_tag, payload})
  end

  defp do_broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Logger.debug("AgentPubSub.broadcast topic=#{topic} tag=#{inspect(message_tag(message))}")
        Phoenix.PubSub.broadcast(@pubsub, topic, message)

      _ ->
        Logger.debug("AgentPubSub.broadcast skipped (no PubSub registry): topic=#{topic}")
        :ok
    end
  end

  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0,
    do: elem(message, 0)
end
