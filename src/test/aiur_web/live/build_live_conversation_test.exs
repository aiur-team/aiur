defmodule AiurWeb.BuildLiveConversationTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.LiveViewAsync

  defmodule Source do
    def prepare(ref, opts) do
      send(opts[:test_pid], {:prepare, ref.id})
      entry = %{identifier: ref.id, workspace_path: opts[:workspace]}
      generation = Agent.get(opts[:control], &Map.get(&1, :generation, ""))
      {:ok, Map.merge(ref, %{handle: "h:" <> ref.id <> generation, path: Path.join(opts[:workspace], "agent.ndjson"), running: entry, fleet: %{fleet: %{running: [entry]}}})}
    end

    def tail(ref, cursor, opts) do
      send(opts[:test_pid], {:tail, ref.id, cursor})

      Agent.get_and_update(opts[:control], fn control ->
        count = control[:pages] || 0

        reply =
          if control[:fail] do
            {:error, :unavailable}
          else
            {:ok,
             %{
               state: :live,
               entries: [%{id: "f:#{count}", k: "say", at: nil, text: "Ticket " <> ref.id}],
               before: "f:10",
               last: "f:#{count}",
               more?: if(cursor == nil, do: true, else: count > 1),
               live?: true,
               observed_at: nil
             }}
          end

        {reply, Map.merge(control, %{pages: max(0, count - 1), fail: false})}
      end)
    end

    def page(_ref, "bad", _opts), do: {:error, :invalid_cursor}
    def page(_ref, "reset", _opts), do: {:error, :reset}

    def page(ref, cursor, opts) do
      send(opts[:test_pid], {:page, ref.id, cursor})
      {:ok, %{entries: [%{id: "f:0", k: "op", at: nil, text: "Earlier"}], before: "f:0", more?: false}}
    end

    def subscribe(ref, opts) do
      send(opts[:test_pid], {:subscription, :on, ref.id})
      :ok
    end

    def unsubscribe(ref, opts) do
      send(opts[:test_pid], {:subscription, :off, ref.id})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:aiur, :build_conversation_source)
    control = start_supervised!({Agent, fn -> %{} end})
    workspace = Path.join(System.tmp_dir!(), "conversation-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    Application.put_env(:aiur, :build_conversation_source, {Source, [test_pid: self(), workspace: workspace, control: control]})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :build_conversation_source, previous), else: Application.delete_env(:aiur, :build_conversation_source)
      Aiur.TestCleanup.rm_rf!(workspace)
    end)

    %{control: control, workspace: workspace}
  end

  defp view do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    view
  end

  defp rows, do: Enum.filter(data()["sections"]["hist"] ++ data()["sections"]["now"], &(&1["agent"] != nil and &1["start"] != nil))

  test "first view accepts absent and nil before and returns entries plus lightweight composer" do
    view = view()
    id = hd(rows())["id"]

    for params <- [%{id: id}, %{id: id, before: nil}] do
      render_hook(view, "conversation-page", params)
      assert_reply(view, reply)
      assert reply["kind"] == "conversation"
      assert reply["entries"] == [%{"id" => "f:0", "k" => "say", "at" => nil, "text" => "Ticket " <> id}]
      assert Payload.validate(reply) == :ok
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.conversation_ref.id == id
      assert assigns.conversation_composer.issue_identifier == id
      assert assigns.conversation_composer.writable_target?
      refute Map.has_key?(assigns.conversation_composer, :messages)
      refute Map.has_key?(assigns.conversation_composer, :path)
    end
  end

  test "older pages use pinned id and cursor; invalid cursor refused and reset rereads tail" do
    view = view()
    [row, other | _] = rows()
    render_hook(view, "conversation-page", %{id: row["id"]})
    assert_reply(view, %{"before" => cursor})
    render_hook(view, "conversation-page", %{id: row["id"], before: cursor})
    assert_reply(view, reply)
    assert reply["kind"] == "conversation-earlier"
    assert reply["entries"] == [%{"id" => "f:0", "k" => "op", "at" => nil, "text" => "Earlier"}]
    assert Payload.validate(reply) == :ok

    for params <- [%{id: other["id"], before: cursor}, %{id: row["id"], before: "bad"}] do
      render_hook(view, "conversation-page", params)
      assert_reply(view, %{"reason" => "invalid_params"})
    end

    render_hook(view, "conversation-page", %{id: row["id"], before: "reset"})
    assert_reply(view, %{"kind" => "conversation", "reset" => true})
  end

  test "unknown, doc and malformed requests never invoke conversation source" do
    view = view()
    doc = Enum.find(data()["sections"]["plan"] ++ data()["sections"]["nq"], &(&1["agent"] == nil or &1["start"] == nil))

    for params <- [%{}, %{id: "../escape"}, %{id: "9000000000"}, %{id: doc["id"]}, %{id: hd(rows())["id"], before: 5}] do
      render_hook(view, "conversation-page", params)
      assert_reply(view, %{"reason" => "invalid_params"})
      refute_received {:prepare, _}
      refute_received {:tail, _, _}
    end
  end

  test "close cancels timer, unsubscribes once and ignores stale polls and other ids" do
    view = view()
    id = hd(rows())["id"]
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, %{"kind" => "conversation"})
    assigns = :sys.get_state(view.pid).socket.assigns
    timer = assigns.conversation_timer
    assert is_integer(Process.read_timer(timer))
    render_hook(view, "conversation-close", %{id: "999999"})
    assert_reply(view, %{"kind" => "ok"})
    refute_received {:subscription, :off, _}
    render_hook(view, "conversation-close", %{id: id})
    assert_reply(view, %{"kind" => "ok"})
    assert Process.read_timer(timer) == false
    assert_received {:subscription, :off, ^id}
    render_hook(view, "conversation-close", %{id: id})
    assert_reply(view, %{"kind" => "ok"})
    refute_received {:subscription, :off, _}
    send(view.pid, {:build_conversation_poll, assigns.conversation_poll_token})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.conversation_ref == nil
  end

  test "switch cancels old timer and unsubscribes before subscribing to new ticket" do
    view = view()
    [a, b | _] = rows()
    render_hook(view, "conversation-page", %{id: a["id"]})
    assert_reply(view, %{"kind" => "conversation"})
    timer = :sys.get_state(view.pid).socket.assigns.conversation_timer
    render_hook(view, "conversation-page", %{id: b["id"]})
    assert_reply(view, %{"kind" => "conversation"})
    assert Process.read_timer(timer) == false
    assert_received {:subscription, :off, aid}
    assert aid == a["id"]
    assert_received {:subscription, :on, bid}
    assert bid == a["id"]
    assert_received {:subscription, :on, bid}
    assert bid == b["id"]
    assert :sys.get_state(view.pid).socket.assigns.conversation_ref.id == b["id"]
  end

  test "read-only reads work and generation_handle change signals append and update state" do
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    view = view()
    id = hd(rows())["id"]
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, %{"kind" => "conversation"})
    send(view.pid, {:live_conversation_changed, %{generation_handle: "h:" <> id}})
    render(view)
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-append", "id" => ^id})
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-state", "state" => "live"})
    assert_received {:tail, ^id, "f:0"}
  end

  test "fleet change adopts a replacement handle even when its first tail read fails", %{control: control} do
    view = view()
    id = hd(rows())["id"]
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, %{"kind" => "conversation"})
    Agent.update(control, &Map.merge(&1, %{generation: ":new", fail: true}))
    send(view.pid, :fleet_changed)
    render(view)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.conversation_handle == "h:" <> id <> ":new"
    assert assigns.conversation_drain
    send(view.pid, {:live_conversation_changed, %{generation_handle: "h:" <> id <> ":new"}})
    render(view)
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-state", "state" => "live"})
    assert_received {:subscription, :off, ^id}
  end

  test "quiescent multi-page appends drain and transient failures are retried", %{control: control, workspace: workspace} do
    view = view()
    id = hd(rows())["id"]
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, %{"kind" => "conversation"})
    File.write!(Path.join(workspace, "agent.ndjson"), "appended")
    Agent.update(control, &Map.merge(&1, %{pages: 3, fail: true}))
    poll(view)
    assert :sys.get_state(view.pid).socket.assigns.conversation_drain
    poll(view)
    assert :sys.get_state(view.pid).socket.assigns.conversation_drain
    poll(view)
    refute :sys.get_state(view.pid).socket.assigns.conversation_drain
    assert_received {:tail, ^id, "f:2"}
  end

  defp poll(view) do
    assigns = :sys.get_state(view.pid).socket.assigns
    send(view.pid, {:build_conversation_poll, assigns.conversation_poll_token})
    render(view)
  end
end
