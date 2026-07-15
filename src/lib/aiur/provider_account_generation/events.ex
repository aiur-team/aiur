defmodule Aiur.ProviderAccountGeneration.Events do
  @moduledoc false

  @pubsub Aiur.PubSub

  @spec broadcast([{String.t(), map(), atom()}]) :: :ok
  def broadcast(changes) do
    Enum.each(changes, fn {topic, snapshot, change} ->
      if is_pid(Process.whereis(@pubsub)) and is_binary(topic) do
        Phoenix.PubSub.broadcast(@pubsub, topic, {:provider_account_generation_changed, Map.put(snapshot, :change, change)})
      end
    end)
  end
end
