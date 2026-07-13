defmodule Aiur.DecisionPubSub do
  @moduledoc """
  Phoenix PubSub helpers for Decision change notifications.

  Best-effort refresh signals only — consumers must re-read the owning
  Decision projection on mount/reconnect rather than trusting a broadcast to
  arrive.
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
    broadcast({:decision_changed, decision_id, version})
  end

  @doc "Broadcasts that the redacted Decision metrics projection changed."
  @spec broadcast_metrics_changed() :: :ok
  def broadcast_metrics_changed do
    broadcast(:decision_metrics_changed)
  end

  defp broadcast(message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, message)

      _other ->
        :ok
    end
  end
end
