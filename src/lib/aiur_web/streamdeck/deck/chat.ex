defmodule AiurWeb.Streamdeck.Deck.Chat do
  @moduledoc "Owner-process conversation tail, subscriptions and bounded refresh."
  import AiurWeb.Streamdeck.Deck.ChatOwner, only: [assign: 2]
  alias Aiur.Conversation.History
  alias AiurWeb.Build.{ConversationPayload, ConversationSource, Payload}
  alias AiurWeb.Streamdeck.Deck.ChatOwner

  @spec init(ChatOwner.socket()) :: ChatOwner.socket()
  def init(socket), do: assign(socket, deck_chat: nil, deck_chat_view: nil)

  @spec open(ChatOwner.socket(), String.t()) :: ChatOwner.socket()
  def open(socket, id) do
    socket = clear(socket)
    state = %{source: ConversationSource.source(), ref: %{id: id}, last: nil, latest: nil, entries: [], timer: nil, token: make_ref(), dirty: false, polls: 0, subscribed: false}
    socket |> assign(deck_chat: state) |> refresh(true) |> schedule()
  end

  @spec clear(ChatOwner.socket()) :: ChatOwner.socket()
  def clear(socket) do
    if state = socket.assigns[:deck_chat] do
      call(state, :unsubscribe, [state.ref])
      if state.timer, do: Process.cancel_timer(state.timer)
    end

    init(socket)
  end

  @spec info(ChatOwner.socket(), term()) :: ChatOwner.socket()
  def info(%{assigns: %{deck_chat: nil}} = socket, _), do: socket

  def info(socket, {:deck_chat_tick, token}) do
    state = socket.assigns.deck_chat

    if state.token == token do
      poll? = state.polls >= 3
      socket = assign(socket, deck_chat: %{state | timer: nil, polls: if(poll?, do: 0, else: state.polls + 1)})
      socket = if state.dirty or poll?, do: refresh(socket, poll?), else: socket
      schedule(socket)
    else
      socket
    end
  end

  def info(socket, {:live_conversation_changed, snapshot}) do
    state = socket.assigns.deck_chat
    if is_binary(state.ref[:handle]) and snapshot[:generation_handle] == state.ref[:handle], do: assign(socket, deck_chat: %{state | dirty: true}), else: socket
  end

  def info(socket, {:live_conversation_restarted, _, _}) do
    state = socket.assigns.deck_chat
    assign(socket, deck_chat: %{state | dirty: true, polls: 3})
  end

  defp refresh(socket, prepare?) do
    state = socket.assigns.deck_chat

    with {:ok, ref} <- if(prepare?, do: call(state, :prepare, [state.ref]), else: {:ok, state.ref}),
         :ok <- resubscribe(state, ref) do
      state = %{state | ref: ref, subscribed: true, dirty: false}
      socket = assign(socket, deck_chat: state)

      read_update(socket, state)
    else
      _ -> unavailable(socket)
    end
  end

  defp read_update(socket, state) do
    with {:ok, view, reset?} <- tail(state),
         :ok <- Payload.validate(%{v: 1, kind: "conversation-append", id: state.ref.id, entries: view.entries, gap: false}) do
      incoming = Enum.map(view.entries, &mask_entry/1)
      entries = if reset?, do: [], else: state.entries
      entries = (entries ++ incoming) |> Enum.reverse() |> Enum.uniq_by(& &1.id) |> Enum.take(100) |> Enum.reverse()
      ChatOwner.logs(socket, state.ref.id, entries)
      latest = List.last(incoming) || if(reset?, do: nil, else: state.latest)
      last = view[:last] || if(reset?, do: nil, else: state.last)
      socket |> assign(deck_chat: %{state | last: last, latest: latest, entries: entries}) |> push_view(view, latest)
    else
      _ -> unavailable(socket)
    end
  end

  defp mask_entry(entry) do
    Enum.reduce([:text, :arg, :res], entry, fn field, masked ->
      case Map.get(masked, field) do
        text when is_binary(text) -> Map.put(masked, field, History.mask_for(%{body: text}, {:device, "streamdeck"}).body)
        _ -> masked
      end
    end)
  end

  defp tail(state) do
    case call(state, :tail, [state.ref, state.last]) do
      {:error, :reset} ->
        case call(state, :tail, [state.ref, nil]) do
          {:ok, view} -> {:ok, view, true}
          error -> error
        end

      {:ok, view} ->
        {:ok, view, false}

      error ->
        error
    end
  end

  defp unavailable(socket), do: push_view(socket, %{state: :unavailable, observed_at: nil}, socket.assigns.deck_chat.latest)

  defp resubscribe(state, ref) do
    if not state.subscribed or state.ref[:handle] != ref[:handle] do
      call(state, :unsubscribe, [state.ref])
      call(state, :subscribe, [ref])
    else
      :ok
    end
  end

  defp push_view(socket, view, latest) do
    state = socket.assigns.deck_chat
    # Entries come only from the shared source's allowlisted wire projection.
    message = Payload.scrub(%{v: 1, kind: "chat", id: state.ref.id, state: view.state, observed_at: ConversationPayload.millis(view[:observed_at]), latest: latest})
    ChatOwner.publish(socket, message)
  end

  defp schedule(socket) do
    state = socket.assigns.deck_chat
    timer = Process.send_after(self(), {:deck_chat_tick, state.token}, 250)
    assign(socket, deck_chat: %{state | timer: timer})
  end

  defp call(state, function, args), do: ConversationSource.call(state.source, function, args)
end
