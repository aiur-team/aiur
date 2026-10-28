defmodule AiurWeb.Streamdeck.ChatTurnsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.{ChatNavigation, ChatPage, Nav, Turns}

  defmodule Source do
    def prepare(ref, _opts), do: {:ok, ref}
    def subscribe(_ref, _opts), do: :ok
    def unsubscribe(_ref, _opts), do: :ok

    def page(ref, before, opts) do
      send(opts[:observer], {:page, ref.id, before})
      opts[:page]
    end

    def tail(ref, before, opts) do
      send(opts[:observer], {:tail, ref.id, before})
      opts[:tail]
    end
  end

  test "assistant turns own preceding tool and system entries; operator turns stand alone" do
    entries = [entry("sys", 1), entry("tool", 2), entry("say", 3), entry("op", 4), entry("tool", 5), entry("say", 6)]
    turns = Turns.group(entries)
    assert Enum.map(turns, & &1.id) == ["t:e3", "t:e4", "t:e6"]
    assert Enum.map(turns, & &1.tools) == [1, 0, 1]
    assert Enum.map(turns, fn turn -> Enum.map(turn.entries, & &1.id) end) == [["e1", "e2", "e3"], ["e4"], ["e5", "e6"]]
    assert Enum.flat_map(turns, & &1.entries) == entries
  end

  test "unfinished tool work remains visible and cannot join across an operator turn" do
    entries = [entry("tool", 1), entry("op", 2), entry("sys", 3), entry("tool", 4)]
    turns = Turns.group(entries)
    assert Enum.map(turns, & &1.id) == ["t:e1", "t:e2", "t:e4"]
    assert Enum.map(turns, & &1.tools) == [1, 0, 1]
    assert Enum.flat_map(turns, & &1.entries) == entries
    assert Turns.group([]) == []
  end

  test "opaque cursor reads prepend entries in desktop order without repeating page boundaries" do
    socket = retained([entry("say", 3), entry("say", 4)], page: {:ok, view([entry("say", 1), entry("say", 2), entry("say", 3)], "opaque:older", true)})
    {reply, socket} = ChatPage.page(socket, "opaque:cursor")
    assert_received {:page, "7", "opaque:cursor"}
    assert reply.kind == "chat-page"
    assert reply.id == "7"
    assert reply.before == "opaque:older"
    assert reply.more
    assert Enum.map(reply.turns, & &1.id) == ["t:e1", "t:e2", "t:e3"]
    assert Enum.map(socket.assigns.deck_chat.entries, & &1.id) == ["e1", "e2", "e3", "e4"]
  end

  test "history cap keeps 500 entries and stops paging before dropping an unseen middle page" do
    tail = Enum.map(10..509, &entry("say", &1))
    older = Enum.map(1..10, &entry("say", &1))
    socket = retained(tail, page: {:ok, view(older, "older", true)})
    {reply, socket} = ChatPage.page(socket, "opaque")
    assert length(socket.assigns.deck_chat.entries) == 500
    assert hd(socket.assigns.deck_chat.entries).id == "e10"
    assert List.last(socket.assigns.deck_chat.entries).id == "e509"
    refute reply.more
    assert Enum.map(reply.turns, & &1.id) == Enum.map(1..10, &"t:e#{&1}")
  end

  test "both invalid and reset cursors discard old pages and reload the tail" do
    for reason <- [:reset, :invalid_cursor] do
      socket = retained([entry("say", 1)], page: {:error, reason}, tail: {:ok, view([entry("say", 9)], "tail:cursor", true)})
      nav = socket.assigns.deck_nav
      socket = put_in(socket.assigns.deck_nav, %{nav | chat: %{nav.chat | selected: "t:e1", offset: 2}, scroll: 20})
      {reply, socket} = ChatPage.page(socket, "bad:cursor")
      assert_received {:page, "7", "bad:cursor"}
      assert_received {:tail, "7", nil}
      assert reply.reset
      assert Enum.map(reply.turns, & &1.id) == ["t:e9"]
      assert socket.assigns.deck_nav.chat.selected == nil
      assert socket.assigns.deck_nav.chat.offset == 0
      assert socket.assigns.deck_nav.scroll == 0
    end
  end

  test "unavailable or invalid older payloads preserve the existing page without claiming success" do
    for response <- [{:error, :unavailable}, {:ok, view([Map.put(entry("say", 1), :raw, "private")], "older", true)}] do
      socket = retained([entry("say", 3)], page: response)
      {reply, unchanged} = ChatPage.page(socket, "opaque")
      assert reply == %{reason: "unavailable"}
      assert unchanged == socket
    end

    socket = retained([entry("say", 3)])
    assert {%{reason: "invalid_chat_page"}, ^socket} = ChatPage.page(socket, nil)
  end

  test "turn paging keeps LIVE pinned and selected turn stable until LIVE is pressed" do
    socket = retained(Enum.map(1..30, fn n -> if n == 24, do: %{entry("say", n) | text: String.duplicate("long selected turn ", 100)}, else: entry("say", n) end))
    nav = socket.assigns.deck_nav
    assert Enum.map(ChatNavigation.visible(nav.chat), & &1.id) == Enum.map(24..30, &"t:e#{&1}")
    {selected, []} = ChatNavigation.reduce(nav, %{"kind" => "key_press", "index" => 0})
    assert selected.chat.selected == "t:e24"
    {scrolled, []} = ChatNavigation.reduce(selected, %{"kind" => "dial_turn", "index" => 0, "ticks" => 3})
    assert scrolled.scroll == 3
    {older, []} = ChatNavigation.reduce(scrolled, %{"kind" => "dial_turn", "index" => 3, "ticks" => -1})
    assert Enum.map(ChatNavigation.visible(older.chat), & &1.id) == Enum.map(17..23, &"t:e#{&1}")
    assert older.chat.selected == "t:e24"
    {live, []} = ChatNavigation.reduce(older, %{"kind" => "key_press", "index" => 7})
    assert live.chat.selected == nil
    assert live.chat.offset == 0
    assert live.scroll == 0
  end

  test "paging past the oldest retained turn asks for the unmodified source cursor" do
    socket = retained(Enum.map(1..7, &entry("say", &1)))
    nav = socket.assigns.deck_nav
    {older, effects} = ChatNavigation.reduce(nav, %{"kind" => "dial_turn", "index" => 3, "ticks" => -1})
    assert effects == [{:chat_page, "first:opaque"}]
    assert older.chat.offset == 1
  end

  test "partial history keys use their displayed right-aligned slots" do
    socket = retained([entry("say", 1), entry("say", 2)])
    nav = socket.assigns.deck_nav
    {empty, []} = ChatNavigation.reduce(nav, %{"kind" => "key_press", "index" => 0})
    assert empty.chat.selected == nil
    {first, []} = ChatNavigation.reduce(nav, %{"kind" => "key_press", "index" => 5})
    assert first.chat.selected == "t:e1"
    {last, []} = ChatNavigation.reduce(nav, %{"kind" => "key_press", "index" => 6})
    assert last.chat.selected == "t:e2"
  end

  test "tail revisions replace the retained entry content without duplicating its turn" do
    socket = retained([entry("say", 1)])
    revised = %{entry("say", 1) | text: "revised text"}
    socket = ChatPage.retain(socket, view([revised], "newer", false), :tail)
    assert socket.assigns.deck_chat.entries == [revised]
    assert [%{id: "t:e1", text: "revised text"}] = socket.assigns.deck_nav.chat.turns
    assert socket.assigns.deck_nav.chat.before == "first:opaque"
    assert socket.assigns.deck_nav.chat.more
  end

  test "scrolling beyond the final text line keeps the final readable page" do
    lines = Enum.map(1..12, fn n -> "line#{n}" <> String.duplicate("x", 86) end)
    latest = %{entry("say", 1) | text: Enum.join(lines, " ")}
    nav = %Nav{scroll: 999}
    [strip] = AiurWeb.Streamdeck.Render.Chat.strip(%{state: :live, latest: latest}, 0, nav)
    assert strip.label =~ "line12"
    refute strip.label =~ "line1x"
    assert strip.svg =~ "line12"
  end

  test "failed oldest-page fetch restores the retained window and names its unavailability" do
    socket = retained(Enum.map(1..7, &entry("say", &1)), page: {:error, :unavailable})
    {nav, [{:chat_page, before}]} = ChatNavigation.reduce(socket.assigns.deck_nav, %{"kind" => "dial_turn", "index" => 3, "ticks" => -1})
    socket = put_in(socket.assigns.deck_nav, nav)
    socket = put_in(socket.assigns.deck_chat_view, %{"state" => "live", "latest" => entry("say", 7)})
    {reply, socket} = ChatPage.page(socket, before)
    assert reply == %{reason: "unavailable"}
    assert socket.assigns.deck_chat_view["state"] == "unavailable"
    [strip] = AiurWeb.Streamdeck.Render.Chat.strip(socket.assigns.deck_chat_view, 0)
    assert strip.label == "Conversation unavailable ● entry 7"
    assert socket.assigns.deck_nav.chat.offset == 0
    assert Enum.map(ChatNavigation.visible(socket.assigns.deck_nav.chat), & &1.id) == Enum.map(1..7, &"t:e#{&1}")
  end

  defp retained(entries, opts \\ []) do
    state = %{
      source: {Source, Keyword.put(opts, :observer, self())},
      ref: %{id: "7"},
      last: "last",
      latest: List.last(entries),
      entries: [],
      before: nil,
      more: false,
      timer: nil,
      token: make_ref(),
      dirty: false,
      polls: 0,
      subscribed: true
    }

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, deck_chat: state, deck_chat_view: nil, deck_nav: %Nav{}}}
    ChatPage.retain(socket, view(entries, "first:opaque", true), :reset)
  end

  defp view(entries, before, more), do: %{state: :live, observed_at: nil, entries: entries, before: before, last: "last", more?: more}
  defp entry("tool", id), do: %{id: "e#{id}", at: id, k: "tool", name: "bash", arg: "command #{id}", res: "result #{id}"}
  defp entry(kind, id), do: %{id: "e#{id}", at: id, k: kind, text: "entry #{id}"}
end
