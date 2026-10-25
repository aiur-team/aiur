defmodule Aiur.AgentPubSub do
  @moduledoc """
  Thin Phoenix.PubSub wrapper for agent events.

  Subscribes and broadcasts on the topics defined in `Aiur.AgentEvents`.
  Modeled on `Aiur.Signal`: a single source of truth
  for the agent-side topic vocabulary, plus a defensive `Process.whereis` guard
  so producers do not crash when PubSub is not yet started (early boot or test
  contexts).
  """

  require Logger

  alias Aiur.{AgentEvents, AgentPubSub.FleetBroadcast, AgentPubSub.FleetRefresh}

  @pubsub Aiur.PubSub
  @fleet_refresh_topic "agents:fleet_refresh"

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
  defdelegate subscribe_running(), to: Aiur.AgentPubSub.FleetSubscriptions

  @doc "Payload-free fleet invalidations for consumers that read the published snapshot."
  @spec subscribe_fleet_refresh(:atomics.atomics_ref()) :: :ok | {:error, term()}
  defdelegate subscribe_fleet_refresh(latch), to: Aiur.AgentPubSub.FleetSubscriptions

  @doc "Subscribes to payload-free fleet invalidations without running or status events."
  @spec subscribe_fleet_invalidation() :: :ok | {:error, term()}
  def subscribe_fleet_invalidation, do: Phoenix.PubSub.subscribe(@pubsub, @fleet_refresh_topic)

  @spec latest_fleet_summaries() :: [AgentEvents.agent_summary()] | nil
  def latest_fleet_summaries, do: FleetRefresh.latest(self())

  @spec broadcast_fleet_refresh() :: :ok
  def broadcast_fleet_refresh,
    do: do_broadcast(@fleet_refresh_topic, :fleet_changed, FleetRefresh)

  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(@pubsub, AgentEvents.status_topic())

  @spec subscribe_poll_state(GenServer.server()) :: :ok | {:error, term()}
  defdelegate subscribe_poll_state(pubsub \\ @pubsub), to: Aiur.AgentPubSub.FleetSubscriptions

  @doc """
  Broadcasts poll progress and the absolute next-poll deadline for AgentList.
  `checking?` marks active dispatch work; a nil deadline means no next poll is scheduled.
  """
  @spec broadcast_poll_state(%{
          checking?: boolean(),
          next_poll_due_at_ms: integer() | nil,
          max_concurrent_agents: integer() | nil
        }) :: :ok
  def broadcast_poll_state(%{checking?: _, next_poll_due_at_ms: _} = payload),
    do: FleetBroadcast.poll_state(payload)

  @spec broadcast_transcript(AgentEvents.agent_identifier(), AgentEvents.transcript_event()) ::
          :ok
  def broadcast_transcript(identifier, %{role: _, body: _, timestamp: _} = event)
      when is_binary(identifier) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:transcript_event, event})
    do_broadcast(agent_chat_active_topic(), {:agent_chat_active, identifier})
  end

  @doc """
  Subscribes to the global topic signaling visible transcript activity. AgentList
  uses it to mark an agent active once it has produced user-visible content.
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
  def broadcast_control_lifecycle(identifier, payload)
      when is_binary(identifier) and is_map(payload) do
    do_broadcast(AgentEvents.agent_topic(identifier), {:control_lifecycle, payload})
  end

  @spec broadcast_running_change([AgentEvents.agent_summary()]) :: :ok
  def broadcast_running_change(summaries) when is_list(summaries),
    do: FleetBroadcast.running_change(summaries)

  @doc false
  @spec broadcast_running_projection_change([AgentEvents.agent_summary()], term()) :: :ok
  def broadcast_running_projection_change(summaries, signature) when is_list(summaries),
    do: FleetBroadcast.running_projection_change(summaries, signature)

  @spec broadcast_status_change(AgentEvents.agent_identifier(), atom()) :: :ok
  def broadcast_status_change(identifier, status)
      when is_binary(identifier) and is_atom(status) do
    do_broadcast(
      AgentEvents.status_topic(),
      {:status_changed, %{identifier: identifier, status: status}},
      FleetRefresh
    )
  end

  @spec broadcast_turn_event(AgentEvents.agent_identifier(), atom(), map()) :: :ok
  def broadcast_turn_event(identifier, event_tag, payload)
      when is_binary(identifier) and
             event_tag in [:turn_completed, :turn_failed, :turn_cancelled, :turn_input_required] and
             is_map(payload) do
    do_broadcast(
      AgentEvents.agent_topic(identifier),
      {:turn_event, identifier, event_tag, payload}
    )
  end

  @doc """
  Aiur-side turn lifecycle signal. `Aiur.AgentRunner` broadcasts this
  when a single `CodingAgent.run_turn/4` call returns, regardless of
  how many internal codex turns it contained. The opencode bridge
  uses it to close the SSE stream tied to that aiur turn so opencode
  renders ONE assistant message per `run_turn` (Approach C.2).
  `reason` is `:done`, `{:failed, term}`, `:paused`, `:input_required`, or
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

  defp do_broadcast(topic, message, dispatcher \\ Phoenix.PubSub) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Logger.debug("AgentPubSub.broadcast topic=#{topic} tag=#{inspect(message_tag(message))}")
        Phoenix.PubSub.broadcast(@pubsub, topic, message, dispatcher)

      _ ->
        # No PubSub registry — expected in CLI contexts (e.g. `aiur init`) that
        # don't start the full supervision tree. A broadcast with no subscribers
        # is a silent no-op; logging it just adds noise to command output.
        :ok
    end
  end

  defp message_tag(message) when is_atom(message), do: message

  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0,
    do: elem(message, 0)
end
