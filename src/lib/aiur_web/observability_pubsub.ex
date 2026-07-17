defmodule AiurWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @pubsub Aiur.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  @spec subscribe(Phoenix.PubSub.t()) :: :ok | {:error, term()}
  def subscribe(pubsub \\ @pubsub) do
    Phoenix.PubSub.subscribe(pubsub, @topic)
  end

  @spec broadcast_update() :: :ok | {:error, term()}
  @spec broadcast_update(Phoenix.PubSub.t()) :: :ok | {:error, term()}
  def broadcast_update(pubsub \\ @pubsub) do
    case Process.whereis(pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end
end
