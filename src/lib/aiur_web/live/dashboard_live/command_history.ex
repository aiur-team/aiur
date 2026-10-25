defmodule AiurWeb.DashboardLive.CommandHistory do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias AiurWeb.OperatorControlCenter.History
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  @history_statuses [:decided, :acknowledged, :resolved, :dismissed, :moot, :expired]

  # --- Command history -------------------------------------------------------
  #
  # History is an ordered list of rows the operator has loaded, so "Load more"
  # appends one page to what is already on screen. Rows are always read back
  # from the retained store: a Command reaches history because the store says it
  # left the queue, never because a click hid a card.
  #
  # A stream would be the cheaper structure for an append-only table, but a row
  # is now an accordion: expanding one has to re-render that row, and a stream
  # item only re-renders when it is re-inserted — which would also move it to a
  # new position in the list.

  @doc false
  @spec init_history_rows(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init_history_rows(socket) do
    socket
    |> assign(:history_rows, [])
    |> assign(:history_ids, MapSet.new())
    |> assign(:history_cursor, nil)
    |> assign(:history_total, nil)
    |> assign(:history_has_more, false)
    |> assign(:history_health, :ok)
    |> assign(:history_mounted?, false)
  end

  # The table only exists on the Commands routes. Leaving them unmounts the
  # stream container, so coming back has to re-read the first page: a stream
  # whose container was removed has nothing left on the server to re-render.
  # Patching inside the route keeps the container, and therefore the pages the
  # operator already loaded.
  @doc false
  @spec load_history(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def load_history(socket, mode) do
    cond do
      Map.get(socket.assigns, :live_action) not in [:decisions, :decision] ->
        assign(socket, :history_mounted?, false)

      Map.get(socket.assigns, :history_mounted?) != true ->
        socket |> reset_history() |> assign(:history_mounted?, true)

      true ->
        do_load_history(socket, mode)
    end
  end

  defp do_load_history(socket, :first_page), do: do_load_history(socket, :head)

  defp do_load_history(socket, :next_page) do
    case history_page(socket.assigns.history_cursor) do
      {:ok, page} -> append_history(socket, page)
      :error -> assign(socket, :history_health, :unavailable)
    end
  end

  # A payload reload only reconciles the head of the list: newly resolved
  # Commands are inserted, already-streamed rows are left untouched, and the
  # operator's loaded pages are never collapsed back to ten.
  defp do_load_history(socket, :head) do
    case history_page(nil) do
      {:ok, page} -> merge_history_head(socket, page)
      :error -> assign(socket, :history_health, :unavailable)
    end
  end

  defp reset_history(socket) do
    case history_page(nil) do
      {:ok, page} -> reset_history_with(page, socket)
      :error -> assign(socket, :history_health, :unavailable)
    end
  end

  defp reset_history_with(page, socket) do
    socket
    |> assign_retained_counts(page)
    |> assign(:history_rows, page.decisions)
    |> assign(:history_ids, MapSet.new(page.decisions, & &1.decision_id))
    |> assign(:history_cursor, get_in(page, [:pagination, :next_cursor]))
    |> assign(:history_total, get_in(page, [:pagination, :total]))
    |> assign(:history_has_more, not is_nil(get_in(page, [:pagination, :next_cursor])))
    |> assign(:history_health, history_health(page))
  end

  defp append_history(socket, page) do
    new_rows = Enum.reject(page.decisions, &MapSet.member?(socket.assigns.history_ids, &1.decision_id))

    socket
    |> assign_retained_counts(page)
    |> append_history_rows(new_rows)
    |> assign(:history_cursor, get_in(page, [:pagination, :next_cursor]))
    |> assign(:history_total, get_in(page, [:pagination, :total]))
    |> assign(:history_has_more, not is_nil(get_in(page, [:pagination, :next_cursor])))
    |> assign(:history_health, history_health(page))
  end

  defp merge_history_head(socket, page) do
    if MapSet.size(socket.assigns.history_ids) == 0 do
      reset_history_with(page, socket)
    else
      {known_rows, new_rows} =
        Enum.split_with(page.decisions, &MapSet.member?(socket.assigns.history_ids, &1.decision_id))

      socket
      |> assign_retained_counts(page)
      |> refresh_history_rows(known_rows)
      |> prepend_history_rows(new_rows)
      |> assign(:history_total, get_in(page, [:pagination, :total]))
      |> assign(:history_health, history_health(page))
    end
  end

  # The history total and filter-chip counts must come from the same serialized
  # store read. Otherwise a Command created between the payload count read and
  # this page read can transiently render All below Resolved.
  defp assign_retained_counts(socket, %{counts: counts, health: health, scope: scope}) when is_map(counts) do
    assign(socket, :retained_counts, counts |> Map.put(:health, health) |> Map.put(:scope, scope))
  end

  defp assign_retained_counts(socket, _page), do: socket

  # Called after an operator action: the decision is re-read from the store and
  # only joins history if the store itself now reports a history status. A
  # failed write leaves the card exactly where it was.
  @doc false
  @spec promote_history_row(Phoenix.LiveView.Socket.t(), term()) :: term()
  def promote_history_row(socket, decision_id) do
    with true <- Map.get(socket.assigns, :live_action) in [:decisions, :decision],
         {:ok, %{decision: decision}} <- PayloadLoader.detail(decision_id),
         true <- decision.decision_status in @history_statuses do
      # The total stays whatever the store reported for the whole history set;
      # it is never incremented locally, so it cannot drift from the rows.
      #
      # A Command already in the table is refreshed where it sits. Only a
      # Command arriving in history for the first time joins at the head —
      # answering from inside an open row must not make that row jump out from
      # under the operator who is reading it.
      if MapSet.member?(socket.assigns.history_ids, decision_id) do
        refresh_history_rows(socket, [decision])
      else
        prepend_history_rows(socket, [decision])
      end
    else
      _other -> socket
    end
  end

  # A finished Command is read where it lives: expanded inside its own history
  # row. The inbox only ever hoists a Command the operator can still act on from
  # the queue, so a history selection is not promoted to the top of the page.
  #
  # The one exception is a Command that history has not loaded — a deep link
  # past the pages on screen. There is no row to expand, so the card is still
  # the only way to see it.
  @doc false
  @spec inbox_selected_decision(term(), term()) :: term()
  def inbox_selected_decision(selected, history_rows) do
    if history_expanded_id(selected, history_rows), do: nil, else: selected
  end

  @doc false
  @spec history_expanded_id(term(), term()) :: term()
  def history_expanded_id(%{decision_id: decision_id, decision_status: status}, history_rows)
      when status in @history_statuses do
    if Enum.any?(history_rows, &(&1.decision_id == decision_id)), do: decision_id
  end

  def history_expanded_id(_selected, _history_rows), do: nil

  @doc false
  @spec history_action_state(term(), term()) :: term()
  def history_action_state(decision_actions, decision_id) when is_binary(decision_id),
    do: Map.get(decision_actions, decision_id, %{})

  def history_action_state(_decision_actions, _decision_id), do: %{}

  # A row already on screen is replaced in place with the freshly read copy,
  # never skipped. A Command can be revised after it reached history, and a row
  # holding its original answer would contradict the panel that expands out of
  # it — showing fresh facts while open and stale ones the moment it closes.
  # Position is preserved: this is a refresh, not a re-ordering.
  defp refresh_history_rows(socket, []), do: socket

  defp refresh_history_rows(socket, rows) do
    fresh = Map.new(rows, &{&1.decision_id, &1})

    assign(socket, :history_rows, Enum.map(socket.assigns.history_rows, &Map.get(fresh, &1.decision_id, &1)))
  end

  defp append_history_rows(socket, rows) do
    socket
    |> assign(:history_rows, socket.assigns.history_rows ++ rows)
    |> track_history_ids(rows)
  end

  # Prepending re-reads a Command the operator just acted on, so any older copy
  # of the same row is dropped rather than left behind as a stale duplicate.
  defp prepend_history_rows(socket, rows) do
    ids = MapSet.new(rows, & &1.decision_id)
    kept = Enum.reject(socket.assigns.history_rows, &MapSet.member?(ids, &1.decision_id))

    socket
    |> assign(:history_rows, rows ++ kept)
    |> track_history_ids(rows)
  end

  defp track_history_ids(socket, rows) do
    assign(socket, :history_ids, Enum.reduce(rows, socket.assigns.history_ids, &MapSet.put(&2, &1.decision_id)))
  end

  defp history_page(cursor) do
    query =
      %{"lifecycle" => "historic", "limit" => History.page_size()}
      |> then(&if(is_binary(cursor), do: Map.put(&1, "cursor", cursor), else: &1))

    case PayloadLoader.decisions(query) do
      {:ok, page} -> {:ok, page}
      {:error, _reason} -> :error
    end
  end

  defp history_health(%{health: %{status: :unavailable}}), do: :unavailable
  defp history_health(%{health: %{status: :partial}}), do: :degraded
  defp history_health(_page), do: :ok
end
