defmodule Aiur.ProviderMeters.Events do
  @moduledoc false

  @pubsub Aiur.PubSub

  # Generation-scoped subscribers must already hold a binding to name their
  # topic. A daemon-internal projection has no binding — bindings live in the
  # session process's dictionary and die with it — so it needs a topic it can
  # name without one. The payload is identical; only the addressing differs.
  @fanout_topic "provider_meters:observed"

  @spec topic(atom(), atom(), String.t()) :: String.t()
  def topic(provider, backend, generation) when is_binary(generation) and generation != "",
    do: "provider_meters:#{provider}:#{backend}:#{generation}"

  @spec fanout_topic() :: String.t()
  def fanout_topic, do: @fanout_topic

  @spec subscribe(atom(), atom(), String.t()) :: :ok | {:error, :subscription_unavailable}
  def subscribe(provider, backend, generation) when is_binary(generation) and generation != "" do
    subscribe_topic(topic(provider, backend, generation))
  end

  @doc """
  Subscribe to every accepted meter observation regardless of account
  generation. For daemon-internal consumers only: the message carries the
  full snapshot, including the opaque generation, so it must not be relayed
  to a consumer surface without projecting the identity out first.
  """
  @spec subscribe_observed() :: :ok | {:error, :subscription_unavailable}
  def subscribe_observed, do: subscribe_topic(@fanout_topic)

  @spec broadcast(Aiur.ProviderMeterSnapshot.t()) :: :ok
  def broadcast(snapshot), do: do_broadcast(nil, snapshot)

  @doc "Broadcast without delivering the event back to the publishing process."
  @spec broadcast_from(pid(), Aiur.ProviderMeterSnapshot.t()) :: :ok
  def broadcast_from(from, snapshot), do: do_broadcast(from, snapshot)

  defp do_broadcast(from, snapshot) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        message = {:provider_meter_changed, snapshot}

        publish_generation(from, snapshot, message)
        publish(from, @fanout_topic, message)

      _ ->
        :ok
    end
  end

  defp publish_generation(from, %{provider_account_generation: generation} = snapshot, message)
       when is_binary(generation) and generation != "" do
    publish(from, topic(snapshot.provider, snapshot.backend, generation), message)
  end

  defp publish_generation(_from, _snapshot, _message), do: :ok

  defp publish(nil, topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)
  defp publish(from, topic, message), do: Phoenix.PubSub.broadcast_from(@pubsub, from, topic, message)

  defp subscribe_topic(topic) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, topic)
      _ -> {:error, :subscription_unavailable}
    end
  end
end
