defmodule Aiur.Listener.Scheduler do
  @moduledoc "Resolves conversation delivery from the effective listener mode."

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Listener.{ModeStore, Spec, SpecStatus}
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  @type origin :: :agent_chat | :voice_assistant | :http | :tui | :internal

  @spec routing() :: :unavailable | :listener
  defdelegate routing(), to: Aiur.Listener

  @doc false
  @spec routing(keyword()) :: :unavailable | :listener
  defdelegate routing(opts), to: Aiur.Listener

  @spec spec_status() :: term()
  def spec_status, do: SpecStatus.read()

  @doc "Canonical spec v1 idle wake rule; addressing is supplied by the delivery port."
  @spec wakes?(atom(), boolean(), boolean()) :: boolean()
  def wakes?(:steer, _addressed, _from_agent), do: true
  def wakes?(:sync, addressed, from_agent), do: addressed or not from_agent
  def wakes?(:async, addressed, _from_agent), do: addressed
  def wakes?(:mute, _addressed, _from_agent), do: false

  @spec resolve(origin(), map() | nil, map(), atom() | nil) :: {:ok, keyword()} | {:error, atom()}
  def resolve(origin, view, capabilities, fallback), do: resolve(origin, view, capabilities, fallback, [])

  @doc false
  @spec resolve(origin(), map() | nil, map(), atom() | nil, keyword()) :: {:ok, keyword()} | {:error, atom()}
  def resolve(_origin, view, _capabilities, _fallback, opts) do
    case routing(opts) do
      :unavailable -> {:error, :listener_mode_unavailable}
      :listener -> listener(view)
    end
  end

  @doc "Decide an external hook boundary using the pinned table; prompt is the start of a user turn."
  @spec hook_delivers?(String.t(), atom(), atom()) :: boolean()
  def hook_delivers?(harness, mode, boundary) do
    case Spec.scheduler_rows() do
      rows when is_list(rows) ->
        Enum.any?(rows, fn row ->
          row["harness"] == harness and row["mode"] == to_string(mode) and row["event"] == to_string(boundary) and
            row["busy"] == false and row["continuation"] == false and row["delivers"] == true
        end)

      _ ->
        false
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
    |> Enum.filter(&(&1.event_type in [:listener_ping, :async_backlog_notice]))
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
end
