defmodule Aiur.ProviderMeters.Events do
  @moduledoc false

  @pubsub Aiur.PubSub

  # Generation-scoped subscribers must already hold a binding to name their
  # topic. A daemon-internal projection has no binding — bindings live in the
  # session process's dictionary and die with it — so it needs a topic it can
  # name without one. The payload is identical; only the addressing differs.
  @fanout_topic "provider_meters:observed"

  @spec topic(atom(), atom(), String.t()) :: String.t()
  def topic(provider, backend, generation), do: "provider_meters:#{provider}:#{backend}:#{generation}"

  @spec fanout_topic() :: String.t()
  def fanout_topic, do: @fanout_topic

  @spec subscribe(atom(), atom(), String.t()) :: :ok | {:error, :subscription_unavailable}
  def subscribe(provider, backend, generation) do
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
  def broadcast(snapshot) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        message = {:provider_meter_changed, snapshot}
        generation_topic = topic(snapshot.provider, snapshot.backend, snapshot.provider_account_generation)

        Phoenix.PubSub.broadcast(@pubsub, generation_topic, message)
        Phoenix.PubSub.broadcast(@pubsub, @fanout_topic, message)

      _ ->
        :ok
    end
  end

  defp subscribe_topic(topic) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, topic)
      _ -> {:error, :subscription_unavailable}
    end
  end
end
