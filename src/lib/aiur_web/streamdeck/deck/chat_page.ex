defmodule AiurWeb.Streamdeck.Deck.ChatPage do
  @moduledoc "Pinned opaque-cursor reads and bounded retained conversation pages."
  alias AiurWeb.Build.{ConversationSource, Payload}
  alias AiurWeb.Streamdeck.Deck.{Chat, ChatOwner, Turns}

  @spec page(ChatOwner.socket(), term()) :: {map(), ChatOwner.socket()}
  def page(%{assigns: %{deck_chat: state}} = socket, before) when is_map(state) and is_binary(before) and byte_size(before) in 1..512 do
    case ConversationSource.call(state.source, :page, [state.ref, before]) do
      {:ok, view} ->
        if valid?(view) do
          socket = retain(socket, view, :older)
          {Map.put(reply(socket), :turns, Turns.group(Enum.map(view.entries, &Chat.mask_entry/1))), socket}
        else
          {%{reason: "unavailable"}, failed(socket)}
        end

      {:error, reason} when reason in [:reset, :invalid_cursor] ->
        socket = Chat.reload(socket)
        {Map.put(reply(socket), :reset, true), socket}

      _ ->
        {%{reason: "unavailable"}, failed(socket)}
    end
  end

  def page(socket, _before), do: {%{reason: "invalid_chat_page"}, socket}

  @spec retain(ChatOwner.socket(), map(), :tail | :reset | :older) :: ChatOwner.socket()
  def retain(socket, view, direction) do
    state = socket.assigns.deck_chat
    incoming = Enum.map(view.entries, &Chat.mask_entry/1)

    entries =
      case direction do
        :reset -> incoming
        :older -> incoming ++ state.entries
        :tail -> state.entries ++ incoming
      end

    entries = entries |> Enum.reverse() |> Enum.uniq_by(& &1.id) |> Enum.take(500) |> Enum.reverse()
    before = if direction == :tail and state.entries != [], do: state[:before], else: view[:before]
    # Once the cap drops the oldest entries, paging further would silently leave a gap.
    more = length(entries) < 500 and if(direction == :tail and state.entries != [], do: state[:more] || false, else: view[:more?] || false)
    state = Map.merge(state, %{entries: entries, before: before, more: more})
    nav = socket.assigns.deck_nav
    previous = nav.chat || %{selected: nil, offset: 0}
    previous = if direction == :reset, do: %{previous | selected: nil, offset: 0}, else: previous
    turns = Turns.group(entries)
    selected = if Enum.any?(turns, &(&1.id == previous.selected)), do: previous.selected
    chat = %{state: view[:state], latest: List.last(entries), turns: turns, before: before, more: more, selected: selected, offset: min(previous.offset, max(div(length(turns) - 1, 7), 0))}
    ChatOwner.assign(socket, deck_chat: state, deck_nav: %{nav | chat: chat, surface: if(is_nil(nav.chat), do: :chat, else: nav.surface)})
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
