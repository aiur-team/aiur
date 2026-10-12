defmodule Aiur.Signal do
  @moduledoc """
  Synchronous alert port and observability refresh notifications.

  The composition root registers the alert sink under `:aiur, :signal`.
  Alerts run in the caller process, preserving the sink's side-effect order.
  """

  require Logger

  @pubsub Aiur.PubSub
  @topic "observability:dashboard"

  @spec alert(String.t(), keyword()) :: :ok | {:error, term()}
  def alert(topic, opts \\ []) do
    with {:ok, sink} <- alert_sink(topic), do: sink.emit_system(topic, opts)
  end

  @spec agent_alert(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def agent_alert(topic, message, opts \\ []) do
    with {:ok, sink} <- alert_sink(topic), do: sink.emit_custom(topic, message, opts)
  end

  @spec subscribe_refresh() :: :ok | {:error, term()}
  @spec subscribe_refresh(Phoenix.PubSub.t()) :: :ok | {:error, term()}
  def subscribe_refresh(pubsub \\ @pubsub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @spec refresh() :: :ok | {:error, term()}
  @spec refresh(Phoenix.PubSub.t()) :: :ok | {:error, term()}
  def refresh(pubsub \\ @pubsub) do
    case Process.whereis(pubsub) do
      pid when is_pid(pid) ->
        event_id = System.unique_integer([:monotonic, :positive])
        Phoenix.PubSub.broadcast(pubsub, @topic, {:observability_updated, event_id})

      _ ->
        :ok
    end
  end

  defp alert_sink(topic) do
    case Application.get_env(:aiur, :signal, [])[:alert_sink] do
      nil ->
        Logger.error("signal: no alert sink registered; dropped #{topic}")
        {:error, :signal_sink_unregistered}

      sink ->
        {:ok, sink}
    end
  end
end
