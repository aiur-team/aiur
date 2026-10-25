defmodule AiurWeb.DashboardLive.TicketContext do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.BuildOrder.TicketDetail.State, as: TicketDetailState
  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.BuildOrder.TicketHistory.Snapshot, as: TicketHistorySnapshot
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter
  alias AiurWeb.DashboardLive.Conversation
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.DecisionPath
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  # Read the current DASH-032 outcome snapshot on mount/reconnect. On the dead
  # first render, or when the projection process is unreachable, fall back to the
  # loading view rather than crashing the LiveView.
  defp open_ticket_context(socket, %{identity: %TrackerIdentity{} = identity} = row) do
    socket = replace_ticket_context_subscription(socket, identity)
    detail = request_context(:ticket_detail_request_fun, &TicketDetailCoordinator.request/1, identity)
    history = request_context(:ticket_history_request_fun, &TicketHistoryProvider.request/1, identity)

    socket
    |> assign(:ticket_context_identity, identity)
    |> assign(:ticket_context_row, row)
    |> assign_ticket_context(detail, history)
  end

  defp open_ticket_context(socket, _row), do: socket

  defp replace_ticket_context_subscription(socket, identity) do
    if Conversation.same_identity?(socket.assigns.ticket_context_identity, identity) do
      subscribe_ticket_context(socket, identity)
    else
      socket
      |> unsubscribe_ticket_context()
      |> subscribe_ticket_context(identity)
    end
  end

  defp subscribe_ticket_context(socket, identity) do
    key = TrackerIdentity.github_key(identity)
    subscriptions = socket.assigns.ticket_context_subscriptions

    if is_nil(key) do
      socket
    else
      subscriptions =
        subscriptions
        |> ensure_ticket_context_subscription(
          {key, :detail},
          :ticket_detail_subscribe_fun,
          &subscribe_ticket_detail/1,
          identity
        )
        |> ensure_ticket_context_subscription(
          {key, :history},
          :ticket_history_subscribe_fun,
          &subscribe_ticket_history/1,
          identity
        )

      assign(socket, :ticket_context_subscriptions, subscriptions)
    end
  end

  defp ensure_ticket_context_subscription(subscriptions, marker, config_key, default, identity) do
    cond do
      MapSet.member?(subscriptions, marker) -> subscriptions
      call_context(config_key, default, identity) == :ok -> MapSet.put(subscriptions, marker)
      true -> subscriptions
    end
  end

  defp unsubscribe_ticket_context(%{assigns: %{ticket_context_identity: %TrackerIdentity{} = identity}} = socket) do
    key = TrackerIdentity.github_key(identity)

    subscriptions =
      socket.assigns.ticket_context_subscriptions
      |> drop_ticket_context_subscription(
        {key, :detail},
        :ticket_detail_unsubscribe_fun,
        &unsubscribe_ticket_detail/1,
        identity
      )
      |> drop_ticket_context_subscription(
        {key, :history},
        :ticket_history_unsubscribe_fun,
        &unsubscribe_ticket_history/1,
        identity
      )

    assign(socket, :ticket_context_subscriptions, subscriptions)
  end

  defp unsubscribe_ticket_context(socket),
    do: assign(socket, :ticket_context_subscriptions, MapSet.new())

  defp drop_ticket_context_subscription(subscriptions, marker, config_key, default, identity) do
    if MapSet.member?(subscriptions, marker) do
      _result = call_context(config_key, default, identity)
      MapSet.delete(subscriptions, marker)
    else
      subscriptions
    end
  end

  @doc false
  @spec subscribe_ticket_context_resets() :: term()
  def subscribe_ticket_context_resets do
    _result =
      case EndpointConfig.get(:ticket_context_reset_subscribe_fun) do
        fun when is_function(fun, 0) -> fun.()
        _fun -> subscribe_default_ticket_context_resets()
      end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp subscribe_default_ticket_context_resets do
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCoordinator.reset_topic())
    Phoenix.PubSub.subscribe(Aiur.PubSub, TicketHistoryProvider.reset_topic())
  end

  defp subscribe_ticket_detail(identity),
    do: Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCoordinator.topic(identity))

  defp subscribe_ticket_history(identity),
    do: Phoenix.PubSub.subscribe(Aiur.PubSub, TicketHistoryProvider.topic(identity))

  defp unsubscribe_ticket_detail(identity),
    do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, TicketDetailCoordinator.topic(identity))

  defp unsubscribe_ticket_history(identity),
    do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, TicketHistoryProvider.topic(identity))

  defp request_context(config_key, default, identity) do
    case call_context(config_key, default, identity) do
      {:ok, value} -> value
      _error -> nil
    end
  end

  defp call_context(config_key, default, identity) do
    fun = EndpointConfig.get(config_key) || default
    fun.(identity)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp assign_ticket_context(socket, detail, history) do
    identity = socket.assigns.ticket_context_identity
    row = socket.assigns.ticket_context_row
    detail = valid_detail(detail, identity)
    history = valid_history(history, identity)
    context = TicketContextPresenter.present(detail, history, ticket_context_capabilities(row))

    socket
    |> assign(:ticket_context_detail, detail)
    |> assign(:ticket_context_history, history)
    |> assign(:ticket_context, context)
  end

  defp valid_detail(%TicketDetailState{} = detail, identity) do
    if Conversation.same_identity?(detail.identity, identity), do: detail, else: unavailable_detail(identity)
  end

  defp valid_detail(_detail, identity), do: unavailable_detail(identity)

  defp valid_history(%TicketHistorySnapshot{} = history, identity) do
    if Conversation.same_identity?(history.identity, identity), do: history, else: unavailable_history(identity)
  end

  defp valid_history(_history, identity), do: unavailable_history(identity)

  defp unavailable_detail(identity) do
    %TicketDetailState{identity: identity, generation: :unknown, health: :unavailable}
  end

  defp unavailable_history(identity) do
    %TicketHistorySnapshot{
      identity: identity,
      generation: :unknown,
      health: :unavailable,
      status_label: "Ticket history unavailable",
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      entries: [],
      truncated?: false,
      freshness: :unknown,
      source_health: %{activity: :unavailable, history: :unavailable}
    }
  end

  defp ticket_context_capabilities(%{identity: %TrackerIdentity{identifier: identifier}, url: url}) do
    [
      %{
        kind: :github,
        variant: :issue,
        available?: is_binary(url),
        href: url,
        reason: :not_available
      },
      %{kind: :chat, available?: false, reason: :not_available},
      %{
        kind: :commands,
        available?: is_binary(identifier),
        href: DecisionPath.inbox(:all, %{ticket: identifier}),
        reason: :not_available
      }
    ]
  end

  defp ticket_context_capabilities(_row), do: []

  @doc false
  @spec maybe_update_ticket_context(Phoenix.LiveView.Socket.t(), term(), term()) :: Phoenix.LiveView.Socket.t()
  def maybe_update_ticket_context(socket, kind, snapshot) do
    if Conversation.same_identity?(Map.get(snapshot, :identity), socket.assigns.ticket_context_identity) do
      case kind do
        :detail -> assign_ticket_context(socket, snapshot, socket.assigns.ticket_context_history)
        :history -> assign_ticket_context(socket, socket.assigns.ticket_context_detail, snapshot)
      end
    else
      socket
    end
  end

  @doc false
  @spec maybe_reset_ticket_context(Phoenix.LiveView.Socket.t(), term(), term()) :: Phoenix.LiveView.Socket.t()
  def maybe_reset_ticket_context(socket, kind, identity) do
    if Conversation.same_identity?(identity, socket.assigns.ticket_context_identity) do
      reset_selected_ticket_context(socket, kind)
    else
      socket
    end
  end

  @doc false
  @spec reset_selected_ticket_context(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def reset_selected_ticket_context(%{assigns: %{ticket_context_identity: nil}} = socket, _kind), do: socket

  def reset_selected_ticket_context(socket, :detail) do
    assign_ticket_context(socket, nil, socket.assigns.ticket_context_history)
  end

  def reset_selected_ticket_context(socket, :history) do
    assign_ticket_context(socket, socket.assigns.ticket_context_detail, nil)
  end

  @doc false
  @spec refresh_ticket_context_row(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_ticket_context_row(%{assigns: %{ticket_context_identity: nil}} = socket), do: socket

  def refresh_ticket_context_row(socket) do
    rows = get_in(socket.assigns.payload, [:units, :snapshot, :rows]) || []

    case Enum.find(rows, &Conversation.same_identity?(Map.get(&1, :identity), socket.assigns.ticket_context_identity)) do
      nil ->
        socket

      row ->
        socket
        |> assign(:ticket_context_row, row)
        |> assign_ticket_context(socket.assigns.ticket_context_detail, socket.assigns.ticket_context_history)
    end
  end

  @doc false
  @spec on_inspect_unit(term(), term()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_inspect_unit(token, socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    case UnitsPresenter.lookup(catalog, token) do
      {:ok, row} -> {:noreply, open_ticket_context(socket, row)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  @doc false
  @spec on_close_ticket_context(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_close_ticket_context(socket) do
    {:noreply,
     socket
     |> unsubscribe_ticket_context()
     |> assign(:ticket_context, nil)
     |> assign(:ticket_context_detail, nil)
     |> assign(:ticket_context_history, nil)
     |> assign(:ticket_context_identity, nil)
     |> assign(:ticket_context_row, nil)}
  end
end
