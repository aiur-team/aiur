defmodule Aiur.Webhooks.DeliveryModeEvents do
  @moduledoc """
  PubSub announcements of per-repo delivery-mode transitions.

  The Build Order projection reconciles from GitHub when a repo's delivery mode
  degrades (#2313): degradation means deliveries are being dropped, so the
  event-sourced store cannot converge on its own and the rare GraphQL
  reconciliation is owed. The projection cannot poll for that transition — it
  is event-sourced now — so the registry that detects it announces it here, the
  same shape as every other change announcement in this codebase.
  """

  require Logger

  @pubsub Aiur.PubSub
  @topic "webhooks:delivery_mode:changed"

  @doc "The topic every mode transition is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to delivery-mode transitions."
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    :ok
  rescue
    error -> unavailable("subscribe", error)
  catch
    :exit, reason -> unavailable("subscribe", reason)
  end

  @doc "Announces one mode transition."
  @spec publish(term(), term()) :: :ok
  def publish(mode, transition) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:webhook_mode_changed, %{repo: mode.repo, state: mode.state, transition: transition}})
    end

    :ok
  rescue
    error -> unavailable("publish", error)
  catch
    :exit, reason -> unavailable("publish", reason)
  end

  defp unavailable(action, reason) do
    Logger.debug("Webhooks.DeliveryModeEvents #{action} unavailable reason=#{inspect(reason)}")
    :ok
  end
end
