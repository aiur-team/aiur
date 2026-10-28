defmodule AiurWeb.Conversation.Paging do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 4]
  alias Aiur.Conversation.History
  alias AiurWeb.Conversation.{Access, Presenter}

  defp opts(socket), do: [principal: socket.assigns.principal, limit: 50]

  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(socket) do
    case History.subscribe(socket.assigns.id) do
      :ok -> socket
      {:error, reason} -> assign(socket, state: Presenter.state({:error, reason}), reason: reason, read_error: reason)
    end
  end

  @spec load(Phoenix.LiveView.Socket.t(), atom() | {:around, pos_integer()}) :: Phoenix.LiveView.Socket.t()
  def load(socket, direction) do
    case History.list_entries(socket.assigns.id, opts(socket) ++ cursor(socket, direction)) do
      {:ok, page} -> apply_page(socket, page, direction) |> refresh_sessions()
      {:error, reason} -> assign(socket, state: Presenter.state({:error, reason}), reason: reason, read_error: reason)
    end
  end

  @spec reveal(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def reveal(socket, pos) when is_binary(pos) do
    with true <- Access.can_reveal?(socket.assigns.principal),
         {position, ""} <- Integer.parse(pos),
         true <- position in socket.assigns.positions do
      socket
      |> assign(:revealed_positions, MapSet.put(socket.assigns.revealed_positions, position))
      |> refresh_positions([position])
    else
      _ -> socket
    end
  end

  def reveal(socket, _pos), do: socket

  @doc "Re-read loaded positions using this viewer's currently authorized reveal selection."
  @spec refresh_positions(Phoenix.LiveView.Socket.t(), [pos_integer()]) :: Phoenix.LiveView.Socket.t()
  def refresh_positions(socket, positions) do
    socket = assign(socket, :can_reveal, Access.can_reveal?(socket.assigns.principal))

    positions
    |> Enum.uniq()
    |> Enum.filter(&(&1 in socket.assigns.positions))
    |> Enum.reduce(socket, fn pos, acc ->
      case read_position(acc, pos) do
        {:ok, entry} -> stream_insert(acc, :entries, entry, [])
        {:error, reason} -> assign(acc, state: :unavailable, reason: reason, read_error: reason)
      end
    end)
  end

  defp read_position(socket, pos) do
    reveal? = Access.can_reveal?(socket.assigns.principal) and MapSet.member?(socket.assigns.revealed_positions, pos)

    with {:ok, page} <- History.list_entries(socket.assigns.id, Keyword.merge(opts(socket), around: pos, limit: 1, reveal: reveal?)),
         entry when not is_nil(entry) <- Enum.find(page.entries, &(&1.pos == pos)) do
      {:ok, entry}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp entries_for_viewer(socket, entries) do
    revealed = socket.assigns.revealed_positions
    permitted? = Access.can_reveal?(socket.assigns.principal)

    Enum.map(entries, fn entry ->
      if permitted? and MapSet.member?(revealed, entry.pos) do
        restore_reveal(socket, entry)
      else
        History.mask_for(entry, opts(socket))
      end
    end)
  end

  defp restore_reveal(socket, %{redacted: true} = entry) do
    case read_position(socket, entry.pos) do
      {:ok, raw} -> raw
      _ -> entry
    end
  end

  defp restore_reveal(_socket, entry), do: entry

  defp cursor(_socket, {:around, pos}), do: [around: pos]
  defp cursor(socket, :older), do: [before: List.first(socket.assigns.positions, 1)]
  defp cursor(socket, :newer), do: [after: List.last(socket.assigns.positions, 0)]
  defp cursor(_socket, :start), do: [from_start: true]
  defp cursor(_socket, :tail), do: [tail: true]

  defp reset_window?({:around, _}), do: true
  defp reset_window?(direction), do: direction in [:start, :tail]

  defp apply_page(socket, page, direction) do
    page = %{page | entries: entries_for_viewer(socket, page.entries)}
    reset? = reset_window?(direction)
    entries = if direction == :older, do: Enum.reverse(page.entries), else: page.entries
    socket = if reset?, do: stream(socket, :entries, page.entries, reset: true, limit: -500), else: insert(socket, entries, direction)
    positions = if reset?, do: [], else: socket.assigns.positions
    positions = Enum.sort(Enum.uniq(positions ++ Enum.map(page.entries, & &1.pos)))
    positions = Enum.take(positions, if(direction == :older, do: 500, else: -500))
    last = if reset? and direction == :tail, do: List.last(page.entries), else: socket.assigns.last_entry
    live_head = if direction == :tail, do: page.head_pos, else: socket.assigns.live_head
    count = if direction == :tail, do: 0, else: socket.assigns.new_below

    assign(socket,
      page: page,
      positions: positions,
      last_entry: last,
      live_head: live_head,
      mode: direction,
      new_below: count,
      reason: nil,
      read_error: nil,
      degraded: History.degraded?(socket.assigns.id)
    )
  end

  defp insert(socket, entries, :older), do: Enum.reduce(entries, socket, &stream_insert(&2, :entries, &1, at: 0, limit: 500))
  defp insert(socket, entries, _direction), do: Enum.reduce(entries, socket, &stream_insert(&2, :entries, &1, at: -1, limit: -500))

  @spec append(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def append(%{assigns: %{page: nil}} = socket, _entries), do: load(socket, :tail)

  def append(socket, entries) do
    fresh = entries |> Enum.filter(&(&1.pos > socket.assigns.live_head)) |> Enum.sort_by(& &1.pos)
    append_fresh(socket, fresh)
  end

  defp append_fresh(socket, []), do: socket

  defp append_fresh(socket, fresh) do
    head = List.last(fresh).pos
    contiguous? = List.last(socket.assigns.positions, 0) == socket.assigns.live_head and hd(fresh).pos == socket.assigns.live_head + 1
    masked = entries_for_viewer(socket, fresh)
    page = %{socket.assigns.page | head_pos: max(head, socket.assigns.page.head_pos), observed_at: DateTime.utc_now()}
    socket = socket |> refresh_sessions() |> assign(live_head: head, last_entry: List.last(masked), page: page)
    socket = if contiguous?, do: append_window(socket, masked), else: socket
    socket |> count_new(length(fresh), contiguous?) |> present()
  end

  defp append_window(socket, entries) do
    positions = Enum.take(socket.assigns.positions ++ Enum.map(entries, & &1.pos), -500)
    socket |> insert(entries, :tail) |> assign(mode: :append, positions: positions)
  end

  defp count_new(socket, count, at_tail?), do: assign(socket, :new_below, if(at_tail? and socket.assigns.at_bottom, do: 0, else: socket.assigns.new_below + count))

  @spec refresh_sessions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_sessions(socket) do
    case History.list_sessions(socket.assigns.id) do
      {:ok, sessions} -> socket |> assign(:sessions, sessions) |> present()
      {:error, reason} -> assign(socket, state: :unavailable, reason: reason, read_error: reason)
    end
  end

  @spec present(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def present(%{assigns: %{page: nil}} = socket), do: socket

  def present(socket) do
    a = socket.assigns
    state = if a.read_error, do: :unavailable, else: Presenter.state(a.page, sessions: a.sessions, degraded: a.degraded, last_entry: a.last_entry)
    reason = if state == :ended, do: List.last(a.sessions).end_reason, else: a.read_error
    assign(socket, state: state, reason: reason, age: Presenter.age(a.page.observed_at, DateTime.utc_now()))
  end
end
