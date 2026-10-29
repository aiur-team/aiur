defmodule Aiur.Listener.Scheduler do
  @moduledoc "Resolves conversation delivery while keeping listener routing dark by default."

  require Logger
  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Listener.{ModeStore, SpecStatus}
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  @type origin :: :agent_chat | :voice_assistant | :http | :tui | :internal

  @spec routing() :: :legacy | :listener
  def routing, do: routing([])

  @doc false
  @spec routing(keyword()) :: :legacy | :listener
  def routing(opts) do
    flag = Application.get_env(:aiur, :listener_send_routing, :legacy)
    warn_invalid_flag(flag)
    if flag == :listener and Keyword.get_lazy(opts, :spec_status, &spec_status/0) == :ok, do: :listener, else: :legacy
  end

  @spec spec_status() :: term()
  def spec_status, do: SpecStatus.read()

  @spec resolve(origin(), map() | nil, map(), atom() | nil) :: {:ok, keyword()} | {:error, atom()}
  def resolve(origin, view, capabilities, fallback), do: resolve(origin, view, capabilities, fallback, [])

  @doc false
  @spec resolve(origin(), map() | nil, map(), atom() | nil, keyword()) :: {:ok, keyword()} | {:error, atom()}
  def resolve(origin, view, capabilities, _fallback, opts) do
    case routing(opts) do
      :legacy -> legacy(origin, capabilities)
      :listener -> listener(view)
    end
  end

  @spec async_usable?(map()) :: boolean()
  def async_usable?(%{support: %{async: %{status: status}}}), do: status in [:proven, :experimental]
  def async_usable?(_view), do: false

  @spec restamp_fun(map()) :: (map() -> map())
  def restamp_fun(view) do
    usable? = async_usable?(view)

    fn
      %{consume_at: :pull} = delivery when usable? ->
        delivery

      delivery ->
        case listener(view) do
          {:ok, opts} -> Map.merge(Map.delete(delivery, :steer_requested), AgentQueue.operator_message("", "", opts).delivery)
          {:error, _} -> delivery
        end
    end
  end

  @doc false
  @spec muted_request?(String.t(), atom()) :: boolean()
  def muted_request?(identifier, policy) do
    policy == :listener and routing() == :listener and ModeStore.get(identifier).requested == :mute
  end

  @doc false
  @spec silence_nudges(AgentQueueStore.t(), String.t(), map()) :: AgentQueueStore.t()
  def silence_nudges(store, identifier, %{effective: :mute}) do
    store
    |> AgentQueueStore.list_pending(identifier)
    |> Enum.filter(&(&1.event_type == :listener_ping))
    |> Enum.reduce(store, fn item, acc -> elem(AgentQueueStore.mark_superseded(acc, item.id), 0) end)
  end

  def silence_nudges(store, _identifier, _view), do: store

  @doc "Queue a content-free nudge for an addressed async operator message; never claim its body."
  @spec notify_enqueued(map(), map(), map()) :: AgentQueueStore.t()
  def notify_enqueued(state, entry, item) do
    {store, notification} =
      if item.delivery[:listener_mode_at_claim] == :async do
        attrs =
          AgentQueue.coordination_event(item.target_issue_identifier, :listener_ping, %{summary: "You have addressed messages. Call aiur_read_messages to read them."},
            dedupe_key: "listener-ping:#{item.id}"
          )

        AgentQueueStore.enqueue(state.queue_store, attrs)
      else
        {state.queue_store, item}
      end

    DeliveryPolicy.notify_running_queue_update(state, entry, notification)
    store
  end

  defp listener(%{effective: :sync}), do: {:ok, [delivery_policy: :checkpoint, listener_mode: :sync]}
  defp listener(%{effective: mode}) when mode in [:async, :mute], do: {:ok, [listener_mode: mode]}

  defp listener(%{effective: :steer, support: %{steer: %{carrier: :emulated_interrupt}}}),
    do: {:ok, [delivery_policy: :interrupt, fallback: :queue_next, listener_mode: :steer, steer_carrier: :emulated_interrupt]}

  defp listener(%{effective: :steer, support: %{steer: %{carrier: :native}}}),
    do: {:ok, [listener_mode: :steer, steer_carrier: :native]}

  defp listener(_view), do: {:error, :listener_mode_unavailable}

  defp legacy(origin, caps) when origin in [:agent_chat, :voice_assistant], do: DeliveryPolicy.normalize_delivery_request(:interrupt, :queue_next, caps)
  defp legacy(:http, caps), do: DeliveryPolicy.normalize_delivery_request(:checkpoint, nil, caps)
  defp legacy(:tui, caps), do: DeliveryPolicy.normalize_delivery_request(:auto, nil, caps)
  defp legacy(_origin, _caps), do: {:error, :invalid_message}

  defp warn_invalid_flag(flag) when flag in [:legacy, :listener], do: :ok

  defp warn_invalid_flag(_flag) do
    key = {__MODULE__, :invalid_flag_warned}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      Logger.warning("Invalid listener_send_routing; using legacy routing")
    end
  end
end
