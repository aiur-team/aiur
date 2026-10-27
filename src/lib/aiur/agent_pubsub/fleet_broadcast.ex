defmodule Aiur.AgentPubSub.FleetBroadcast do
  @moduledoc "Deduplicates high-volume fleet projections before PubSub fanout."
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub.FleetRefresh}

  @pubsub Aiur.PubSub

  @spec poll_state(map()) :: :ok
  def poll_state(payload) do
    signature = Map.take(payload, [:checking?, :next_poll_due_at_ms, :max_concurrent_agents])
    publish(:poll_state, signature, AgentEvents.poll_state_topic(), {:poll_state_changed, payload})
  end

  @spec running_change([AgentEvents.agent_summary()]) :: :ok
  def running_change(summaries) do
    publish_always(AgentEvents.running_topic(), {:running_changed, summaries}, FleetRefresh)
  end

  @spec running_projection_change([AgentEvents.agent_summary()], term()) :: :ok
  def running_projection_change(summaries, signature) do
    publish(
      :running,
      signature,
      AgentEvents.running_topic(),
      {:running_changed, summaries},
      FleetRefresh
    )
  end

  defp publish(key, signature, topic, message, dispatcher \\ Phoenix.PubSub) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        if FleetRefresh.publish_if_changed(self(), key, signature) == :changed do
          Logger.debug("AgentPubSub.broadcast topic=#{topic} tag=#{inspect(elem(message, 0))}")
          Phoenix.PubSub.broadcast(@pubsub, topic, message, dispatcher)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp publish_always(topic, message, dispatcher) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Logger.debug("AgentPubSub.broadcast topic=#{topic} tag=#{inspect(elem(message, 0))}")
        Phoenix.PubSub.broadcast(@pubsub, topic, message, dispatcher)

      _ ->
        :ok
    end
  end
end
