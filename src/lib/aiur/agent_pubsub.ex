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

  @doc """
  Drop this process's subscription to an agent's transcript topic. The
  opencode bridge MUST call this on every stream-close path: with segmented
  turn streams, opencode reopens a chat-completion per segment on one
  keep-alive connection, and Bandit reuses the handler process. Without an
  explicit unsubscribe, each segment's `subscribe_agent/1` stacks another
  subscription on the same process, so one broadcast transcript event is
  delivered once per stacked subscription and the bridge streams N copies
  of every command/tool row into one assistant message.
  """
  @spec unsubscribe_agent(AgentEvents.agent_identifier()) :: :ok
  def unsubscribe_agent(identifier) when is_binary(identifier) do
    Phoenix.PubSub.unsubscribe(@pubsub, AgentEvents.agent_topic(identifier))
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
          next_poll_due_at_ms: integer() | nil,
          max_concurrent_agents: integer() | nil
        }) :: :ok
  def broadcast_poll_state(%{checking?: _, next_poll_due_at_ms: _} = payload) do
    do_broadcast(AgentEvents.poll_state_topic(), {:poll_state_changed, payload})
  end

  @spec broadcast_transcript(AgentEvents.agent_identifier(), AgentEvents.transcript_event()) :: :ok
  def broadcast_transcript(identifier, %{role: _, body: _, timestamp: _} = event)
      when is_binary(identifier) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:transcript_event, event})
    do_broadcast(agent_chat_active_topic(), {:agent_chat_active, identifier})
  end

  @doc """
  Single global topic that fires `{:agent_chat_active, identifier}`
  every time an agent emits any transcript event. AgentList uses this
  to promote its 🔘 → ⚪ marker once the agent has actually produced
  visible content — duplicates are harmless because subscribers
  dedup with `MapSet.put`.
  """
  @spec subscribe_agent_chat_active() :: :ok | {:error, term()}
  def subscribe_agent_chat_active do
    Phoenix.PubSub.subscribe(@pubsub, agent_chat_active_topic())
  end

  defp agent_chat_active_topic, do: "agents:chat_active"

  @prewarm_topic "prewarm:phase"

  @doc """
  Subscribe to warm-base pre-warm phase events. `Aiur.RepoBase` broadcasts
  `{:prewarm_phase, phase}` as it clones/fetches/builds the shared base; the
  agent list renders a loading bar from these until the base is ready.
  """
  @spec subscribe_prewarm() :: :ok | {:error, term()}
  def subscribe_prewarm, do: Phoenix.PubSub.subscribe(@pubsub, @prewarm_topic)

  @spec broadcast_prewarm_phase(atom() | tuple()) :: :ok
  def broadcast_prewarm_phase(phase) do
    do_broadcast(@prewarm_topic, {:prewarm_phase, phase})
  end

  @spec broadcast_alert(AgentEvents.agent_identifier(), AgentEvents.alert_event()) :: :ok
  def broadcast_alert(identifier, %{name: _, message: _, timestamp: _} = event)
      when is_binary(identifier) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:alert, event})
  end

  @doc "Publishes a normalized, redacted per-unit control lifecycle projection."
  @spec broadcast_control_lifecycle(AgentEvents.agent_identifier(), map()) :: :ok
  def broadcast_control_lifecycle(identifier, payload) when is_binary(identifier) and is_map(payload) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:control_lifecycle, payload})
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
      when is_binary(identifier) and
             event_tag in [:turn_completed, :turn_failed, :turn_cancelled, :turn_input_required] and
             is_map(payload) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:turn_event, identifier, event_tag, payload})
  end

  @doc """
  Aiur-side turn lifecycle signal. `Aiur.AgentRunner` broadcasts this
  when a single `CodingAgent.run_turn/4` call returns, regardless of
  how many internal codex turns it contained. The opencode bridge
  uses it to close the SSE stream tied to that aiur turn so opencode
  renders ONE assistant message per `run_turn` (Approach C.2).
  `reason` is `:done`, `{:failed, term}`, `:input_required`, or
  `:cancelled`.
  """
  @spec broadcast_aiur_turn_done(AgentEvents.agent_identifier(), String.t(), term()) :: :ok
  def broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
      when is_binary(identifier) and is_binary(aiur_turn_id) do
    do_broadcast(
      AgentEvents.agent_topic(identifier),
      {:aiur_turn_done, identifier, aiur_turn_id, reason}
    )
  end

  defp do_broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Logger.debug("AgentPubSub.broadcast topic=#{topic} tag=#{inspect(message_tag(message))}")
        Phoenix.PubSub.broadcast(@pubsub, topic, message)

      _ ->
        # No PubSub registry — expected in CLI contexts (e.g. `aiur init`) that
        # don't start the full supervision tree. A broadcast with no subscribers
        # is a silent no-op; logging it just adds noise to command output.
        :ok
    end
  end

  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0,
    do: elem(message, 0)
end
