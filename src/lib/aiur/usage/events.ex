defmodule Aiur.Usage.Events do
  @moduledoc false

  @netlify_topic "aiur:netlify_usage"

  @spec netlify_topic() :: String.t()
  def netlify_topic, do: @netlify_topic

  @spec subscribe_netlify() :: :ok
  def subscribe_netlify, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @netlify_topic)

  @spec broadcast_netlify(map()) :: :ok
  def broadcast_netlify(snapshot),
    do: Phoenix.PubSub.broadcast(Aiur.PubSub, @netlify_topic, {:netlify_usage_changed, snapshot})
end
