Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationLiveTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.Conversation.{History, Ingest, Ref, TestSupport}
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport

  setup context, do: TestSupport.setup(context)

  defp open(ref), do: live(build_conn(), "/conversations/" <> Ref.conversation_id(ref))

  test "loading then ordered tail, older pages and start to newer navigation", %{ref: ref} do
    Ingest.append(ref, source(), Enum.map(1..120, &event/1))
    assert :ok = flush(ref)
    conn = get(build_conn(), "/conversations/" <> Ref.conversation_id(ref))
    assert html_response(conn, 200) =~ "Loading conversation"
    refute conn.resp_body =~ "No messages yet"
    {:ok, view, html} = open(ref)
    assert positions(html) == Enum.to_list(71..120)
    assert positions(render_click(element(view, "button", "Load older"))) == Enum.to_list(21..120)
    assert positions(render_click(element(view, "button", "Jump to start"))) == Enum.to_list(1..50)
    assert positions(render_click(element(view, "button", "Load newer"))) == Enum.to_list(1..100)
    assert positions(render_click(element(view, "button", "Latest entries"))) == Enum.to_list(71..120)
  end

  test "overlapping broadcasts are discarded and scrolled-up entries counted and masked", %{ref: ref} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    {:ok, view, _} = open(ref)
    assert {:ok, page} = History.list_entries(ref, principal: :internal)
    send(view.pid, {:entries_appended, Ref.conversation_id(ref), page.entries})
    assert positions(render(view)) == [1]
    render_hook(view, "at_bottom", %{"value" => false})
    secret = "ghp_" <> String.duplicate("a", 36)
    Ingest.append(ref, source(), [event(2), event(3), %{event(4) | body: secret}])
    assert :ok = flush(ref)
    html = render(view)
    assert positions(html) == [1, 2, 3, 4]
    assert html =~ "3 new entries below"
    refute html =~ secret
    render_hook(view, "at_bottom", %{"value" => true})
    refute has_element?(view, "#conversation-new")
  end

  test "not found differs from empty and partial history has a banner", %{ref: ref} do
    {:ok, view, html} = live(build_conn(), "/conversations/conv_bad")
    assert html =~ "Conversation not found"
    refute has_element?(view, "[data-state=known_empty]")
    Ingest.append(ref, %{source() | start_reason: :import}, [event(1)])
    assert :ok = flush(ref)
    {:ok, _view, html} = open(ref)
    assert html =~ "Earlier history is not available"
  end

  test "writer failure keeps stale content, survives remount, and recovers", %{ref: ref, control: control} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    {:ok, view, _} = open(ref)
    actions(control, :append, [{:error, :enospc}])
    Ingest.append(ref, source(), [event(2)])
    assert {:error, :degraded} = flush(ref)
    assert History.degraded?(Ref.conversation_id(ref))
    assert render(view) =~ "Stale — journal unavailable"
    assert has_element?(view, "#entry-1")
    assert render(view) =~ "seconds ago"
    {:ok, resumed, html} = open(ref)
    assert html =~ "Stale — journal unavailable"
    assert :ok = flush(ref)
    refute History.degraded?(Ref.conversation_id(ref))
    assert has_element?(view, "[data-state=live]")
    assert has_element?(resumed, "[data-state=live]")
  end

  test "session changes preserve restart and unknown causes", %{ref: ref} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    {:ok, view, _} = open(ref)
    Ingest.end_session(ref, "session-one", :daemon_restart_unknown)
    assert :ok = flush(ref)
    assert has_element?(view, "[data-state=restart_unknown]")
    Ingest.append(ref, source("next"), [event(2)])
    assert :ok = flush(ref)
    assert has_element?(view, "[data-state=live]")
    assert has_element?(view, ".conversation-divider", "Session 2")
    Ingest.end_session(ref, "next", :future_reason)
    assert :ok = flush(ref)
    assert has_element?(view, "[data-state=unknown]")
  end

  test "empty and unreadable journals remain distinct through ticks and retry", %{ref: ref, dir: dir} do
    assert :ok = flush(ref)
    {:ok, empty, html} = open(ref)
    assert html =~ "No messages yet"
    refute has_element?(empty, "[data-state=not_found]")
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    {:ok, view, _} = open(ref)
    path = Aiur.Conversation.Store.segment_path(dir, 1)
    bytes = File.read!(path)
    File.write!(path, "broken\n")
    render_click(element(view, "button", "Latest entries"))
    assert has_element?(view, "[data-state=unavailable]")
    assert has_element?(view, "#entry-1")
    send(view.pid, :age_tick)
    assert has_element?(view, "[data-state=unavailable]")
    File.write!(path, bytes)
    render_click(element(view, "button", "Retry"))
    assert has_element?(view, "[data-state=live]")
  end

  test "an older-page snapshot cannot acknowledge a queued live broadcast", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), Enum.map(1..100, &event/1))
    assert :ok = flush(ref)
    {:ok, view, _} = open(ref)
    render_hook(view, "at_bottom", %{"value" => false})
    # Commit first, deliver later: the same boundary used by the journal writer.
    entry = %Aiur.Conversation.Entry{pos: 101, session_seq: 1, role: "agent", kind: "message", body: "racing entry", observed_at: DateTime.utc_now()}
    assert {:ok, head} = Aiur.Conversation.Store.append_entries(dir, state(ref).segment_state, [entry])
    Aiur.Conversation.HeadTable.put(Ref.conversation_id(ref), dir, head)
    render_click(element(view, "button", "Load older"))
    send(view.pid, {:entries_appended, Ref.conversation_id(ref), [entry]})
    assert positions(render(view)) == Enum.to_list(1..101)
    assert has_element?(view, "#conversation-new", "1 new entries below")
    send(view.pid, {:entries_appended, Ref.conversation_id(ref), [entry]})
    assert positions(render(view)) == Enum.to_list(1..101)
  end

  test "broadcasts at the start refresh activity without mixing distant pages", %{ref: ref} do
    old = DateTime.add(DateTime.utc_now(), -700)
    events = Enum.map(1..120, &Map.put(event(&1), :timestamp, old))
    Ingest.append(ref, source(), events)
    assert :ok = flush(ref)
    {:ok, view, _} = open(ref)
    assert has_element?(view, "[data-state=idle]")
    render_click(element(view, "button", "Jump to start"))
    Ingest.append(ref, source(), [event(121)])
    assert :ok = flush(ref)
    assert has_element?(view, "[data-state=live]")
    assert has_element?(view, "#conversation-new", "1 new entries below")
    assert positions(render(view)) == Enum.to_list(1..50)
    assert positions(render_click(element(view, "button", "Latest entries"))) == Enum.to_list(72..121)
  end

  defp positions(html) do
    html |> Floki.parse_document!() |> Floki.find("[data-pos]") |> Enum.map(fn node -> node |> Floki.attribute("data-pos") |> hd() |> String.to_integer() end)
  end
end
