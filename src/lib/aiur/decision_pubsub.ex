defmodule Aiur.DecisionPubSub do
  @moduledoc """
  Phoenix PubSub helpers for Decision change notifications.

  Best-effort refresh signals only — consumers must re-read the owning
  Decision projection on mount/reconnect rather than trusting a broadcast to
  arrive.
  """

  @pubsub Aiur.PubSub
  @topic "decisions:changed"
  @reconcile_topic "decisions:dispatches_reconciled"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Subscribes to the completion signal for `DecisionStore` dispatch reconciliation.

  Subscribers receive `{:decision_dispatches_reconciled, %{store: pid(),
  fences: non_neg_integer(), dispatched: [entry]}}` once per reconciliation
  pass, where each `entry` is `%{decision_id:, action_id:, version:, kind:}`
  and `kind` is `:dispatch` (a first delivery the pass scheduled) or
  `:reconcile_queue` (an already-queued delivery it re-queued).

  A reconciliation pass otherwise has no outward signal: it schedules work and
  returns, so "the pass ran and scheduled exactly one dispatch" and "the pass
  has not run yet" were distinguishable only by waiting a fixed number of
  milliseconds and reading silence as an answer — which is a function of
  machine load rather than of the store's behaviour. `dispatched` names what
  the pass did, so exactly-once reconciliation becomes directly assertable,
  and each entry carries the version that produced it, so a pass that
  re-dispatches a stale answer is visible in the payload instead of only as a
  duplicate side effect a caller must sit and wait for.
  """
  @spec subscribe_dispatches_reconciled() :: :ok | {:error, term()}
  def subscribe_dispatches_reconciled do
    Phoenix.PubSub.subscribe(@pubsub, @reconcile_topic)
  end

  @doc "Broadcasts the outcome of one dispatch-reconciliation pass. Best-effort; a missing PubSub server is a no-op."
  @spec broadcast_dispatches_reconciled(pid(), non_neg_integer(), [map()]) :: :ok
  def broadcast_dispatches_reconciled(store, fences, dispatched)
      when is_pid(store) and is_integer(fences) and is_list(dispatched) do
    broadcast(
      @reconcile_topic,
      {:decision_dispatches_reconciled, %{store: store, fences: fences, dispatched: dispatched}}
    )
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

  defp broadcast(message), do: broadcast(@topic, message)

  defp broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, topic, message)

      _other ->
        :ok
    end
  end
end
