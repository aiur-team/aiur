defmodule AiurWeb.Conversation.Session do
  @moduledoc "Shared conversation mount, subscriptions and chronology initialization."
  import Phoenix.Component
  import Phoenix.LiveView
  alias Aiur.Conversation.Ref
  alias AiurWeb.Conversation.{Commands, ComposerEvents, Navigation, Paging, Presenter}

  @spec mount(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(id, session, socket) do
    principal = AiurWeb.Conversation.Access.principal(session, socket)

    socket =
      socket
      |> assign(
        id: id,
        executor?: id == Ref.conversation_id(Ref.executor()),
        principal: principal,
        can_reveal: AiurWeb.Conversation.Access.can_reveal?(principal),
        state: :loading,
        page: nil,
        positions: [],
        revealed_positions: MapSet.new(),
        live_head: 0,
        sessions: [],
        last_entry: nil,
        read_error: nil,
        degraded: false,
        at_bottom: true,
        new_below: 0,
        reason: nil,
        mode: :tail,
        highlight_pos: nil,
        age: Presenter.age(nil, DateTime.utc_now())
      )
      |> stream_configure(:entries, dom_id: &"entry-#{&1.pos}")
      |> stream(:entries, [])
      |> ComposerEvents.init()
      |> Navigation.init()
      |> Commands.init()

    if connected?(socket) do
      Process.send_after(self(), :age_tick, 30_000)
      {:ok, socket |> Paging.subscribe() |> Navigation.load() |> Commands.subscribe()}
    else
      {:ok, socket}
    end
  end
end
