defmodule AiurWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @spec subscribe() :: :ok | {:error, term()}
  defdelegate subscribe(), to: Aiur.Signal, as: :subscribe_refresh

  @spec subscribe(Phoenix.PubSub.t()) :: :ok | {:error, term()}
  defdelegate subscribe(pubsub), to: Aiur.Signal, as: :subscribe_refresh

  @spec broadcast_update() :: :ok | {:error, term()}
  defdelegate broadcast_update(), to: Aiur.Signal, as: :refresh

  @spec broadcast_update(Phoenix.PubSub.t()) :: :ok | {:error, term()}
  defdelegate broadcast_update(pubsub), to: Aiur.Signal, as: :refresh
end
