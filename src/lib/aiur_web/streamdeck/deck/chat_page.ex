defmodule AiurWeb.Streamdeck.Deck.ChatPage do
  @moduledoc "Pinned opaque-cursor reads and bounded retained conversation pages."
  alias AiurWeb.Build.{ConversationSource, Payload}
  alias AiurWeb.Streamdeck.Deck.{Chat, ChatOwner, Turns}

  @spec page(ChatOwner.socket(), term()) :: {map(), ChatOwner.socket()}
  def page(%{assigns: %{deck_chat: state}} = socket, before) when is_map(state) and is_binary(before) and byte_size(before) in 1..512 do
    case ConversationSource.call(state.source, :page, [state.ref, before]) do
      {:ok, view} ->
        older_page(socket, view)

      {:error, reason} when reason in [:reset, :invalid_cursor] ->
        socket = Chat.reload(socket)
        {Map.put(reply(socket), :reset, true), socket}

      _ ->
        {%{reason: "unavailable"}, failed(socket)}
    end
  end

  def page(socket, _before), do: {%{reason: "invalid_chat_page"}, socket}

  defp older_page(socket, view) do
    if valid?(view) do
      state = socket.assigns.deck_chat
      breakpoints = if(view.more?, do: [], else: Chat.read_breakpoints(state, view.entries))
      breakpoints = Enum.uniq_by(state.breakpoints ++ breakpoints, & &1.id)
      socket = ChatOwner.assign(socket, deck_chat: %{state | breakpoints: breakpoints})
      socket = retain(socket, view, :older)
      entries = project_entries(view.entries, socket.assigns.deck_chat.breakpoints)
      {Map.put(reply(socket), :turns, Turns.group(Enum.map(entries, &Chat.mask_entry/1))), socket}
    else
      {%{reason: "unavailable"}, failed(socket)}
    end
  end

  @spec retain(ChatOwner.socket(), map(), :tail | :reset | :older) :: ChatOwner.socket()
  def retain(socket, view, direction) do
    state = Map.put_new(socket.assigns.deck_chat, :breakpoints, [])
    entries = merge_entries(state.entries, Enum.map(project_entries(view.entries, state.breakpoints), &Chat.mask_entry/1), direction)
    {before, more} = cursor(state, view, direction, length(entries))
    state = Map.merge(state, %{entries: entries, before: before, more: more})
    nav = socket.assigns.deck_nav
    chat = projection(nav.chat, view, entries, before, more, direction)
    surface = if is_nil(nav.chat), do: :chat, else: nav.surface
    ChatOwner.assign(socket, deck_chat: state, deck_nav: %{nav | chat: chat, surface: surface})
  end

  defp project_entries(entries, breakpoints) do
    times = entries |> Enum.map(& &1[:at]) |> Enum.filter(&is_integer/1)

    case times do
      [] ->
        entries

      _ ->
        first = Enum.min(times)
        last = Enum.max(times)
        inserted = Enum.filter(breakpoints, &(&1.at >= first and &1.at <= last))
        (entries ++ inserted) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(&{&1.at || -1, &1.id})
    end
  end

  defp merge_entries(retained, incoming, direction) do
    entries =
      case direction do
        :reset -> incoming
        :older -> incoming ++ retained
        :tail -> retained ++ incoming
      end

    entries |> Enum.reverse() |> Enum.uniq_by(& &1.id) |> Enum.take(500) |> Enum.reverse()
  end

  defp cursor(state, _view, :tail, count) when state.entries != [], do: {state[:before], count < 500 and (state[:more] || false)}
  # At the cap, stop before dropping an unseen middle page.
  defp cursor(_state, view, _direction, count), do: {view[:before], count < 500 and (view[:more?] || false)}

  defp projection(previous, view, entries, before, more, direction) do
    previous = if direction == :reset, do: nil, else: previous
    previous = previous || %{selected: nil, offset: 0}
    turns = Turns.group(entries)
    selected = if Enum.any?(turns, &(&1.id == previous.selected)), do: previous.selected
    %{state: view[:state], latest: List.last(entries), turns: turns, before: before, more: more, selected: selected, offset: min(previous.offset, max(div(length(turns) - 1, 7), 0))}
  end

  defp failed(socket) do
    nav = socket.assigns.deck_nav
    chat = nav.chat
    chat = if chat, do: %{chat | offset: min(chat.offset, max(div(length(chat.turns) - 1, 7), 0))}
    socket = ChatOwner.assign(socket, deck_nav: %{nav | chat: chat})
    if socket.assigns[:deck_chat_view], do: ChatOwner.publish(socket, Map.put(socket.assigns.deck_chat_view, "state", "unavailable")), else: socket
  end

  defp valid?(view), do: Payload.validate(%{v: 1, kind: "conversation-append", id: "1", entries: view.entries, gap: false}) == :ok

  defp reply(socket) do
    chat = socket.assigns.deck_nav.chat || %{turns: [], before: nil, more: false}
    %{v: 1, kind: "chat-page", id: socket.assigns.deck_chat.ref.id, turns: chat.turns, before: chat.before, more: chat.more}
  end
end
