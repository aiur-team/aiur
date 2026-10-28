defmodule AiurWeb.Conversation.Navigation do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 4, push_event: 3]
  alias Aiur.Conversation.{Anchors, History, JumpPoints}
  alias AiurWeb.Conversation.Paging

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    visible = for kind <- JumpPoints.kinds(), JumpPoints.entry(kind).default_visible, do: to_string(kind)

    socket
    |> assign(anchors: [], visible_kinds: visible, event_start: 0, event_has_newer: false, jump_placement: nil, highlight_pos: nil, pending_pos: nil, position_notice: nil, anchor_error: nil)
    |> Phoenix.LiveView.stream_configure(:events, dom_id: &"event-#{&1["event"]["event_id"]}-#{&1["kind"]}")
    |> stream(:events, [], [])
  end

  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    case History.list_anchors(socket.assigns.id) do
      {:ok, anchors} -> socket |> assign(anchors: sort(anchors), anchor_error: nil) |> events(:latest)
      {:error, _} -> assign(socket, :anchor_error, "Events unavailable")
    end
  end

  @spec added(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def added(socket, anchor) do
    anchors = Anchors.strongest(socket.assigns.anchors ++ [anchor]) |> sort()
    previous = Enum.filter(socket.assigns.anchors, &(&1["event"]["event_id"] == anchor["event"]["event_id"]))
    latest = socket.assigns.anchors |> Enum.count(&(&1["kind"] in socket.assigns.visible_kinds)) |> Kernel.-(1000) |> max(0)
    direction = if socket.assigns.event_start == latest, do: :latest, else: :current
    socket = socket |> assign(anchors: anchors, anchor_error: nil) |> events(direction)

    (previous ++ [anchor])
    |> Enum.map(& &1["pos"])
    |> Enum.uniq()
    |> Enum.filter(&(&1 in socket.assigns.positions))
    |> Enum.reduce(socket, fn pos, acc ->
      case History.list_entries(acc.assigns.id, principal: acc.assigns.principal, around: pos, limit: 1) do
        {:ok, %{entries: [entry]}} -> stream_insert(acc, :entries, entry, [])
        _ -> acc
      end
    end)
  end

  @spec filters(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def filters(socket, kinds) when is_list(kinds) do
    allowed = Enum.map(JumpPoints.kinds(), &to_string/1)
    socket |> assign(:visible_kinds, Enum.filter(kinds, &(&1 in allowed))) |> events(:latest)
  end

  def filters(socket, _), do: socket

  @spec events(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def events(socket, direction) do
    selected = Enum.filter(socket.assigns.anchors, &(&1["kind"] in socket.assigns.visible_kinds))
    latest = max(length(selected) - 1000, 0)

    start =
      case direction do
        :latest -> latest
        :older -> max(socket.assigns.event_start - 1000, 0)
        :current -> min(socket.assigns.event_start, latest)
      end

    socket |> assign(event_start: start, event_has_newer: start < latest) |> stream(:events, Enum.slice(selected, start, 1000), reset: true, limit: 1000)
  end

  @spec params(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def params(socket, %{"pos" => value} = params) when is_binary(value) do
    placement = if params["placement"] == "after" and is_binary(params["event"]), do: {params["event"], params["kind"]}, else: params["placement"]
    socket = assign(socket, :jump_placement, placement)

    case Integer.parse(value) do
      {pos, ""} when pos > 0 -> jump(socket, pos, true)
      _ -> socket |> Paging.load(:tail) |> assign(highlight_pos: nil, pending_pos: nil, position_notice: "Position not found")
    end
  end

  def params(socket, %{"pos" => _}), do: socket |> Paging.load(:tail) |> assign(highlight_pos: nil, pending_pos: nil, position_notice: "Position not found")

  def params(socket, _), do: socket |> clear() |> Paging.load(:tail)

  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket), do: assign(socket, highlight_pos: nil, pending_pos: nil, position_notice: nil, jump_placement: nil)

  @spec retry(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def retry(%{assigns: %{pending_pos: nil}} = socket), do: socket
  def retry(socket), do: jump(socket, socket.assigns.pending_pos, false)

  defp jump(socket, pos, retry?) do
    socket = Paging.load(socket, {:around, pos})

    case socket.assigns.read_error do
      nil ->
        socket |> assign(highlight_pos: pos, pending_pos: nil, position_notice: nil) |> push_event("conversation-jump", %{})

      :not_found ->
        socket
        |> Paging.load(:tail)
        |> assign(highlight_pos: nil, pending_pos: if(retry?, do: pos), position_notice: "Position not found")

      _ ->
        assign(socket, highlight_pos: nil, pending_pos: nil, position_notice: "Position unavailable")
    end
  end

  @spec markers([map()], integer()) :: [map()]
  def markers(anchors, pos), do: anchors |> Enum.filter(&(&1["pos"] == pos and &1["placement"] == "after")) |> Enum.sort_by(& &1["event"]["event_id"])
  @spec highlight?([map()], integer(), term()) :: boolean()
  def highlight?(anchors, pos, {event_id, kind}) do
    case Enum.find(anchors, &(to_string(&1["event"]["event_id"]) == event_id and &1["kind"] == kind)) do
      %{"placement" => "at"} -> true
      %{"placement" => "after"} -> false
      _ -> highlight?(anchors, pos, "after")
    end
  end

  def highlight?(anchors, pos, "after"), do: not Enum.any?(anchors, &(&1["pos"] == pos and &1["placement"] == "after"))

  def highlight?(anchors, pos, _) do
    at_pos = Enum.filter(anchors, &(&1["pos"] == pos))
    Enum.any?(at_pos, &(&1["placement"] == "at")) or not Enum.any?(at_pos, &(&1["placement"] == "after"))
  end

  defp sort(anchors), do: Enum.sort_by(anchors, &{timestamp(&1["event"]["observed_at"]), &1["event"]["event_id"]})

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_unix(at, :microsecond)
      _ -> 0
    end
  end

  defp timestamp(_), do: 0
end
