defmodule AiurWeb.BuildLiveConversationEventsTest do
  # Event rows arrive live without a polling timer of their own: one debounced
  # read per trigger burst, nothing pushed twice, nothing pushed for a ticket
  # that is no longer open.
  use Aiur.TestSupport.BuildHome.ProtocolCase

  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.TestSupport.{EndpointStubs, LiveViewAsync}
  alias Aiur.TrackerIdentity

  defmodule Source do
    alias AiurWeb.Build.ConversationSource.Wave0bEvents

    def prepare(ref, _opts), do: {:ok, Map.merge(ref, %{handle: nil, path: nil, running: nil})}

    def tail(ref, _cursor, _opts),
      do: {:ok, %{state: :live, entries: [%{id: "t:" <> ref.id, k: "say", at: 1_791_407_600_000, text: "hi"}], before: "t:0", last: "t:0", more?: true, live?: true, observed_at: nil}}

    def page(_ref, _cursor, _opts), do: {:ok, %{entries: [], before: nil, more?: false}}
    def subscribe(_ref, opts), do: if(Agent.get(opts[:control], & &1[:subscribe_fail]), do: {:error, :down}, else: :ok)
    def unsubscribe(_ref, _opts), do: :ok
    def events_subscribe(identity, _opts), do: Wave0bEvents.subscribe(identity)
    def events_unsubscribe(topic, _opts), do: Wave0bEvents.unsubscribe(topic)
    def events(ref, opts), do: {:ok, Agent.get(opts[:control], &Map.put(&1, :identity, identity(ref.id)))}

    def identity(id),
      do: %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "I-" <> id, identifier: id, reason: nil}
  end

  setup do
    previous = Application.get_env(:aiur, :build_conversation_source)
    control = start_supervised!({Agent, fn -> %{log: {:ok, []}, history: {:error, :none}, merges: [], decisions: {:ok, []}, pause: nil, repository: nil, read_at: 0} end})
    Application.put_env(:aiur, :build_conversation_source, {Source, [control: control]})
    test_pid = self()

    EndpointStubs.scope(
      build_events_timer: fn _pid, message, ms ->
        send(test_pid, {:timer, message, ms})
        make_ref()
      end
    )

    on_exit(fn -> if previous, do: Application.put_env(:aiur, :build_conversation_source, previous), else: Application.delete_env(:aiur, :build_conversation_source) end)
    %{control: control}
  end

  defp view do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    view
  end

  defp rows, do: Enum.filter(data()["sections"]["hist"] ++ data()["sections"]["now"], &(&1["agent"] != nil and &1["start"] != nil))

  defp line(id, ticket, ts \\ "2026-10-07T21:20:00Z"), do: %{kind: "self", id: id, topic: "ticket.#{ticket}.agent.blocked", ts: ts, summary: "line #{id}"}

  defp open(view, id) do
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, reply)
    reply
  end

  defp event_ids(reply), do: for(%{"k" => "ev", "id" => id} <- reply["entries"], do: id)

  test "L1 history updates debounce into one read; a new line is appended once", %{control: control} do
    view = view()
    id = hd(rows())["id"]
    Agent.update(control, &%{&1 | log: {:ok, [line(1, id)]}})
    assert "ev:log:1" in event_ids(open(view, id))

    for _ <- 1..3, do: send(view.pid, {:ticket_history_updated, nil})
    render(view)
    assert_received {:timer, {:conversation_events_refresh, ^id}, 1_000}
    refute_received {:timer, _, _}

    Agent.update(control, &%{&1 | log: {:ok, [line(1, id), line(2, id)]}})
    send(view.pid, {:conversation_events_refresh, id})
    render(view)
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-append", "entries" => [%{"id" => "ev:log:2", "label" => "Blocked"}]})

    send(view.pid, {:ticket_history_updated, nil})
    send(view.pid, {:conversation_events_refresh, id})
    render(view)
    refute_push_event(view, "build-conversation", %{"kind" => "conversation-append"})
  end

  test "E18/E19 an append is sent once, a first view repeats its window, a late lower id is still found", %{control: control} do
    view = view()
    id = hd(rows())["id"]
    Agent.update(control, &%{&1 | log: {:ok, [line(50, id)]}})
    assert "ev:log:50" in event_ids(open(view, id))

    send(view.pid, {:conversation_events_refresh, id})
    render(view)
    refute_push_event(view, "build-conversation", %{"kind" => "conversation-append"})

    Agent.update(control, &%{&1 | log: {:ok, [line(50, id), line(49, id)]}})
    send(view.pid, {:conversation_events_refresh, id})
    render(view)
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-append", "entries" => [%{"id" => "ev:log:49"}]})

    assert ["ev:log:49", "ev:log:50"] -- event_ids(open(view, id)) == []
  end

  test "L2 resuming from paused pushes one live \"Resumed\" row that a new first view does not carry" do
    view = view()
    row = hd(rows())
    id = row["id"]
    open(view, id)

    for {state, now} <- [{"paused", 1_791_407_000_000}, {"active", 1_791_407_600_000}] do
      send(view.pid, {:build_changes, %{"now" => now, "upsert" => [put_in(row, ["agent", "state"], state)], "remove" => [], "set" => %{}}})
    end

    render(view)
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-append", "entries" => [%{"ev" => "commit", "label" => "Resumed", "at" => 1_791_407_600_000}]})
    refute "ev:resume:1791407600000" in event_ids(open(view, id))
  end

  test "an unreadable log is one visible row on the first view", %{control: control} do
    view = view()
    id = hd(rows())["id"]
    Agent.update(control, &%{&1 | log: {:error, {:unavailable, :eisdir}}, read_at: 7})
    assert [%{"id" => "ev:sys:unreadable", "k" => "sys", "text" => "Ticket events could not be read", "at" => 7} | _] = open(view, id)["entries"]
  end

  test "L3 a refresh scheduled for a ticket no longer open pushes nothing", %{control: control} do
    view = view()
    [a, b | _] = rows()
    Agent.update(control, &%{&1 | log: {:ok, [line(1, a["id"])]}})
    open(view, a["id"])
    send(view.pid, {:ticket_history_updated, nil})
    render(view)
    assert_received {:timer, {:conversation_events_refresh, aid}, _}
    open(view, b["id"])
    Agent.update(control, &%{&1 | log: {:ok, [line(1, a["id"]), line(2, a["id"])]}})
    send(view.pid, {:conversation_events_refresh, aid})
    render(view)
    refute_push_event(view, "build-conversation", %{"kind" => "conversation-append"})
  end

  test "a conversation that fails to open leaves no history subscription behind", %{control: control} do
    view = view()
    id = hd(rows())["id"]
    Agent.update(control, &Map.put(&1, :subscribe_fail, true))
    assert %{"kind" => "error", "reason" => "unavailable"} = open(view, id)
    refute view.pid in Enum.map(Registry.lookup(Aiur.PubSub, TicketHistoryProvider.topic(Source.identity(id))), &elem(&1, 0))
    assert :sys.get_state(view.pid).socket.assigns.conversation_events_topic == nil
  end

  test "L4 closing releases the history subscription" do
    view = view()
    id = hd(rows())["id"]
    open(view, id)
    topic = TicketHistoryProvider.topic(Source.identity(id))
    assert view.pid in Enum.map(Registry.lookup(Aiur.PubSub, topic), &elem(&1, 0))

    render_hook(view, "conversation-close", %{id: id})
    assert_reply(view, %{"kind" => "ok"})
    Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:ticket_history_updated, nil})
    render(view)
    refute_received {:timer, _, _}
    refute view.pid in Enum.map(Registry.lookup(Aiur.PubSub, topic), &elem(&1, 0))
  end
end
