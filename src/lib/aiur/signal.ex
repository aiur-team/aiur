defmodule Aiur.Signal do
  @moduledoc """
  Synchronous alert port and observability refresh notifications.

  The composition root registers the alert sink under `:aiur, :signal`.
  Alerts run in the caller process, preserving the sink's side-effect order.
  Lifecycle telemetry delegates synchronously to the optional `:lifecycle_sink`;
  an unregistered lifecycle sink is a valid run shape and silently returns `:ok`.
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

  @spec lifecycle(
          String.t(),
          String.t() | nil,
          atom() | String.t(),
          atom() | String.t(),
          map(),
          keyword()
        ) :: :ok
  def lifecycle(ticket, attempt_id, event, boundary, metadata \\ %{}, opts \\ []) do
    case lifecycle_sink() do
      nil -> :ok
      sink -> sink.record(ticket, attempt_id, event, boundary, metadata, opts)
    end
  end

  @spec backend_message(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def backend_message(ticket, attempt_id, backend, message, opts \\ []) do
    case lifecycle_sink() do
      nil -> :ok
      sink -> sink.observe_backend_message(ticket, attempt_id, backend, message, opts)
    end
  end

  @doc "Creates an opaque identity for one dispatched worker attempt."
  @spec new_attempt_id(String.t()) :: String.t()
  def new_attempt_id(ticket) when is_binary(ticket) do
    suffix = 10 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{ticket}:#{suffix}"
  end

  @doc "Classifies a failure reason into a bounded, body-free string."
  @spec reason_class(term()) :: String.t()
  def reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_class(%{__struct__: module}) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  def reason_class({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  def reason_class({tag, _detail, _more}) when is_atom(tag), do: Atom.to_string(tag)
  def reason_class(status) when is_integer(status), do: "status_#{status}"
  def reason_class(_reason), do: "unknown"

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

  defp lifecycle_sink, do: Application.get_env(:aiur, :signal, [])[:lifecycle_sink]

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
