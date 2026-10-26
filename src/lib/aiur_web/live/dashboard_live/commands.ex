defmodule AiurWeb.DashboardLive.Commands do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  alias AiurWeb.DashboardLive.CommandHistory
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.DashboardLive.Conversation
  alias AiurWeb.DashboardLive.TicketContext
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.OperatorControlCenter.AgentLogModal
  alias AiurWeb.OperatorControlCenter.DecisionPath
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  @decision_filters [:all, :open, :blocking, :undelivered, :supervisor, :resolved, :superseded]

  @doc false
  @spec reload_payload(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def reload_payload(socket, mode) do
    payload = PayloadLoader.load(mode)

    socket
    |> assign(:payload, payload)
    |> assign(:retained_counts, Map.get(payload, :retained_counts, unavailable_retained_counts()))
    |> assign(:now, DateTime.utc_now())
    |> assign(:agent_log_modal, AgentLogModal.refresh(socket.assigns.agent_log_modal, payload))
    |> UnitsPanel.assign_units_view()
    |> Controls.sync_unit_control_subscriptions(connected?(socket))
    |> Controls.reconcile_unit_controls()
    |> TicketContext.refresh_ticket_context_row()
    |> Conversation.refresh_conversation_row()
    |> reload_decision_page()
    |> CommandHistory.load_history(:head)
    |> assign_selected_decision(socket.assigns.selected_decision_id)
  end

  @doc false
  @spec reload_after_action(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reload_after_action(socket) do
    socket
    |> reload_payload(:fresh)
    |> PayloadLoader.mark_loaded()
  end

  @doc false
  @spec assign_selected_decision(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def assign_selected_decision(socket, decision_id) do
    {selected, status, health} =
      case PayloadLoader.detail(decision_id) do
        :none -> {nil, :none, nil}
        {:ok, %{decision: decision, health: health}} -> {decision, :available, health}
        {:error, :not_found} -> {nil, :not_found, nil}
        {:error, {:indeterminate, health}} -> {nil, :indeterminate, health}
        {:error, {:invalid_decision_id, _reason}} -> {nil, :not_found, nil}
        {:error, _reason} -> {nil, :unavailable, nil}
      end

    socket
    |> clear_stale_action_state(selected)
    |> assign(:selected_decision_id, decision_id)
    |> assign(:selected_decision, selected)
    |> assign(:selected_decision_status, status)
    |> assign(:selected_decision_health, health)
  end

  @doc false
  @spec selected_decision_error_title(term()) :: term()
  def selected_decision_error_title(:unavailable), do: "Command unavailable"
  def selected_decision_error_title(:indeterminate), do: "Command presence unknown"
  def selected_decision_error_title(_status), do: "Command not found"

  @doc false
  @spec selected_decision_error_message(term(), term()) :: term()
  def selected_decision_error_message(:unavailable, decision_id),
    do: "Retained Command data is currently unavailable for #{decision_id}. The overview remains available."

  def selected_decision_error_message(:indeterminate, decision_id),
    do: "#{decision_id} may exist in a part we cannot read, so it cannot be reported as missing. The overview is still available."

  def selected_decision_error_message(_status, decision_id),
    do: "No retained Command matches #{decision_id}."

  @doc false
  @spec partial_detail?(term()) :: term()
  def partial_detail?(%{status: :partial}), do: true
  def partial_detail?(_health), do: false

  defp clear_stale_action_state(socket, nil), do: socket

  defp clear_stale_action_state(socket, %{decision_id: decision_id} = selected) do
    identity = decision_identity(selected)

    case Map.get(socket.assigns.decision_actions, decision_id) do
      nil ->
        socket

      %{decision_identity: ^identity} ->
        socket

      _state ->
        assign(socket, :decision_actions, Map.delete(socket.assigns.decision_actions, decision_id))
    end
  end

  defp decision_identity(decision) do
    {Map.get(decision, :version), Map.get(decision, :active_action_id)}
  end

  @doc false
  @spec unavailable_retained_counts() :: term()
  def unavailable_retained_counts do
    %{
      open: nil,
      blocking: nil,
      total: nil,
      awaiting: nil,
      awaiting_blocking: nil,
      deferred: nil,
      health: %{status: :unavailable, label: "Command counts unavailable"}
    }
  end

  @doc false
  @spec normalize_filter(term()) :: term()
  def normalize_filter(filter) when is_atom(filter) and filter in @decision_filters, do: filter

  def normalize_filter(filter) when is_binary(filter) do
    Enum.find(@decision_filters, :all, &(Atom.to_string(&1) == filter))
  end

  def normalize_filter(_filter), do: :all

  @doc false
  @spec decision_path(term(), term(), term()) :: term()
  def decision_path(nil, filter, query), do: DecisionPath.inbox(filter, query)
  def decision_path(decision_id, filter, query), do: DecisionPath.detail(decision_id, filter, query)

  @doc false
  @spec assign_decision_page(Phoenix.LiveView.Socket.t(), term(), term()) :: Phoenix.LiveView.Socket.t()
  def assign_decision_page(socket, filter, params) do
    case Map.get(socket.assigns, :live_action) do
      :decisions ->
        do_assign_decision_page(socket, filter, params)

      :decision ->
        socket
        |> assign(:decision_page, fallback_decision_page(socket.assigns.payload))
        |> assign(:decision_query, decision_query(filter, params))

      _action ->
        socket
    end
  end

  defp do_assign_decision_page(socket, filter, params) do
    query = decision_query(filter, params)

    page =
      case PayloadLoader.decisions(provider_query(filter, query)) do
        {:ok, page} -> page
        {:error, reason} -> unavailable_decision_page(reason)
      end

    socket
    |> assign(:decision_page, page)
    |> assign(:decision_query, query)
  end

  defp reload_decision_page(socket) do
    case Map.get(socket.assigns, :live_action) do
      :decisions -> do_reload_decision_page(socket)
      :decision -> assign(socket, :decision_page, fallback_decision_page(socket.assigns.payload))
      _action -> socket
    end
  end

  defp do_reload_decision_page(socket) do
    filter = Map.get(socket.assigns, :decision_filter, :all)
    query = Map.get(socket.assigns, :decision_query, %{})

    page =
      case PayloadLoader.decisions(provider_query(filter, query)) do
        {:ok, page} -> page
        {:error, reason} -> unavailable_decision_page(reason)
      end

    assign(socket, :decision_page, page)
  end

  defp decision_query(:all, params) do
    %{}
    |> maybe_put_query(:ticket, params["ticket"])
    |> maybe_put_query(:search, params["search"])
    |> maybe_put_query(:cursor, params["cursor"])
    |> maybe_put_query(:sort, UnitsPanel.normalize_table_sort(params["sort"]))
  end

  defp decision_query(_filter, params) do
    %{}
    |> maybe_put_query(:cursor, params["cursor"])
    |> maybe_put_query(:sort, UnitsPanel.normalize_table_sort(params["sort"]))
  end

  defp provider_query(filter, query) do
    query
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("limit", 25)
    |> put_filter_query(filter)
  end

  # The inbox lists outstanding Commands, including work deferred to the
  # Executor. Only completed or retired Commands move into history.
  defp put_filter_query(query, :open), do: Map.put(query, "lifecycle", "open")

  defp put_filter_query(query, :blocking), do: query |> Map.put("lifecycle", "open") |> Map.put("blocking", true)
  defp put_filter_query(query, :resolved), do: Map.put(query, "lifecycle", "historic")
  defp put_filter_query(query, :all), do: Map.put(query, "lifecycle", "open")
  defp put_filter_query(query, _filter), do: query

  defp maybe_put_query(query, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> query
      value -> Map.put(query, key, value)
    end
  end

  defp maybe_put_query(query, _key, _value), do: query

  @doc false
  @spec empty_decision_page() :: term()
  def empty_decision_page do
    %{
      decisions: [],
      health: %{status: :available, partial?: false},
      pagination: %{total: 0, next_cursor: nil, label: "Retained Command page"}
    }
  end

  @doc false
  @spec fallback_decision_page(term()) :: term()
  def fallback_decision_page(payload) do
    decisions = Map.get(payload, :decisions, [])

    %{
      decisions: decisions,
      health: %{status: :available, partial?: false},
      pagination: %{
        total: length(decisions),
        next_cursor: nil,
        label: "Priority Command overview"
      }
    }
  end

  defp unavailable_decision_page(reason) do
    %{
      decisions: [],
      health: %{status: :unavailable, partial?: true, reason: reason},
      pagination: %{total: nil, next_cursor: nil, label: "Retained Command page unavailable"}
    }
  end

  @doc false
  @spec page_provider_health(term()) :: term()
  def page_provider_health(%{health: %{status: status}}) when status in [:available, :partial], do: :ok
  def page_provider_health(_page), do: :unavailable

  @doc false
  @spec on_search_commands(term(), term()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_search_commands(search, socket) do
    query =
      case String.trim(search) do
        "" -> %{}
        search -> %{search: String.slice(search, 0, 200)}
      end

    {:noreply, push_patch(socket, to: DecisionPath.inbox(:all, query))}
  end
end
