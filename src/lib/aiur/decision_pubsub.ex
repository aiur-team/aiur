defmodule Aiur.DecisionPubSub do
  @moduledoc """
  Phoenix PubSub helpers for Decision change notifications.

  Best-effort refresh signal only — consumers must treat `Aiur.DecisionStore`
  as the source of truth and re-read on mount/reconnect rather than trusting
  this broadcast alone to arrive.
  """

  @pubsub Aiur.PubSub
  @topic "decisions:changed"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc "Broadcasts that `decision_id` changed to `version`. Best-effort; a missing PubSub server is a no-op."
  @spec broadcast_changed(String.t(), pos_integer()) :: :ok
  def broadcast_changed(decision_id, version) when is_binary(decision_id) and is_integer(version) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:decision_changed, decision_id, version})

      _other ->
        :ok
    end
  end
end
