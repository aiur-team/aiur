defmodule Aiur.AgentPubSub.FleetSubscriptions do
  @moduledoc false

  alias Aiur.{AgentEvents, AgentPubSub.FleetRefresh}

  @pubsub Aiur.PubSub
  @fleet_refresh_topic "agents:fleet_refresh"

  @spec subscribe_running() :: :ok | {:error, term()}
  def subscribe_running do
    result = Phoenix.PubSub.subscribe(@pubsub, AgentEvents.running_topic())
    FleetRefresh.reset_projection_signatures(:running)
    result
  end

  @spec subscribe_fleet_refresh(:atomics.atomics_ref()) :: :ok | {:error, term()}
  def subscribe_fleet_refresh(latch) do
    :ok = FleetRefresh.register(self())
    :ok = FleetRefresh.reset_projection_signatures(:running)
    opts = [metadata: {:fleet_refresh, latch}]
    :ok = Phoenix.PubSub.subscribe(@pubsub, AgentEvents.running_topic(), opts)
    :ok = Phoenix.PubSub.subscribe(@pubsub, AgentEvents.status_topic(), opts)
    Phoenix.PubSub.subscribe(@pubsub, @fleet_refresh_topic, opts)
  end

  @spec subscribe_poll_state(GenServer.server()) :: :ok | {:error, term()}
  def subscribe_poll_state(pubsub \\ @pubsub) do
    result = Phoenix.PubSub.subscribe(pubsub, AgentEvents.poll_state_topic())
    FleetRefresh.reset_projection_signatures(:poll_state)
    result
  end
end
