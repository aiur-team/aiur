defmodule AiurWeb.StreamdeckChannelChatTest do
  use Aiur.TestSupport
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.LiveConversation.Notify

  setup do
    root = Aiur.TestSupport.tmp_root!("deck-chat")
    Aiur.TestSupport.write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    workspace = Path.join([root, "owner", "aiur", "7"])
    File.mkdir_p!(Path.join(workspace, "logs"))
    put_endpoint_config(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: []}} end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, workspace: workspace}
  end

  test "focus reads retained history with an empty event feed and polls file appends", %{workspace: workspace} do
    path = Path.join(workspace, "logs/agent.ndjson")
    File.write!(path, line("seeded reply"))
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"id" => "7", "state" => "ended", "latest" => %{"k" => "say", "text" => "seeded reply"}}, 2_000)
    assert_push("logs", %{"transcript" => rows}, 2_000)
    assert Enum.any?(rows, &(&1["body"] == "seeded reply"))
    File.write!(path, line("appended reply"), [:append])
    assert_push("chat", %{"latest" => %{"text" => "appended reply"}}, 2_000)
    assert_push("logs", %{"transcript" => rows}, 2_000)
    assert Enum.any?(rows, &(&1["body"] == "appended reply"))
    assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
  end

  test "missing retained logs have a named state" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"state" => "not_retained", "latest" => nil}, 2_000)
  end

  test "channel subscriptions and timers are removed on refocus, unfocus and terminate", %{workspace: workspace} do
    handle = Notify.random_handle()
    running = %{identifier: "7", issue_id: "node7", workspace_path: workspace, live_conversation: %{generation_handle: handle}}
    put_endpoint_config(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end)
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"id" => "7"}, 2_000)
    pid = socket.channel_pid
    topic = Notify.handle_topic(handle)
    assert {^pid, _} = List.keyfind(Registry.lookup(Aiur.PubSub, topic), pid, 0)
    timer = :sys.get_state(pid).assigns.deck_chat.timer
    assert_reply(push(socket, "focus", %{"identifier" => "8"}), :ok, %{"focused" => "8"})
    assert_push("chat", %{"id" => "8"}, 2_000)
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(timer) == false
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"id" => "7"}, 2_000)
    timer = :sys.get_state(pid).assigns.deck_chat.timer
    assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(timer) == false
    assert :sys.get_state(pid).assigns.deck_chat == nil
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"id" => "7"}, 2_000)
    timer = :sys.get_state(pid).assigns.deck_chat.timer
    Process.unlink(pid)
    close(socket)
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(timer) == false
  end

  defmodule Source do
    @behaviour AiurWeb.Build.ConversationSource
    alias Aiur.Conversation.History
    def prepare(ref, opts), do: {:ok, Map.put(ref, :handle, opts[:handle])}

    def tail(_ref, cursor, opts) do
      send(opts[:observer], {:chat_tail, self(), cursor})
      Agent.get(opts[:agent], & &1)
    end

    def page(_ref, _cursor, _opts), do: {:error, :unsupported}
    def subscribe(ref, _), do: History.live_subscribe(ref.handle)
    def unsubscribe(%{handle: handle}, _), do: History.live_unsubscribe(handle)
    def unsubscribe(_, _), do: :ok
  end

  test "live changes coalesce and keep the source cursor without replaying legacy events" do
    handle = Notify.random_handle()
    agent = start_supervised!({Agent, fn -> view("first", "cursor-1") end})
    source({Source, agent: agent, handle: handle, observer: self()})
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"latest" => %{"text" => "first"}}, 2_000)
    pid = socket.channel_pid
    assert_receive {:chat_tail, ^pid, nil}, 1_000
    Agent.update(agent, fn _ -> view("last", "cursor-2") end)
    for _ <- 1..25, do: send(pid, {:live_conversation_changed, %{generation_handle: handle}})
    assert_push("chat", %{"latest" => %{"text" => "last"}}, 1_000)
    assert_receive {:chat_tail, ^pid, "cursor-1"}, 1_000
    refute_push("chat", _, 150)
    assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
  end

  test "source errors and invalid entries fail closed instead of exposing raw fields" do
    handle = Notify.random_handle()
    agent = start_supervised!({Agent, fn -> {:error, :unavailable} end})
    source({Source, agent: agent, handle: handle, observer: self()})
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"state" => "unavailable", "latest" => nil}, 2_000)
    {:ok, clean} = view("message", "next")
    Agent.update(agent, fn _ -> {:ok, %{clean | entries: [%{id: "x", at: nil, k: "say", text: "message", raw: "secret"}]}} end)
    send(socket.channel_pid, {:live_conversation_changed, %{generation_handle: handle}})
    assert_push("chat", %{"state" => "unavailable", "latest" => nil}, 1_000)
    assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
  end

  defp view(text, cursor), do: {:ok, %{state: :live, observed_at: DateTime.utc_now(), entries: [%{id: cursor, at: nil, k: "say", text: text}], last: cursor}}

  defp source(value) do
    previous = Application.fetch_env(:aiur, :build_conversation_source)
    Application.put_env(:aiur, :build_conversation_source, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:aiur, :build_conversation_source, old)
        :error -> Application.delete_env(:aiur, :build_conversation_source)
      end
    end)
  end

  defp line(text) do
    Jason.encode!(%{event: "notification", timestamp: DateTime.to_iso8601(DateTime.utc_now()), raw: Jason.encode!(%{method: "item/agentMessage/delta", params: %{delta: text}})}) <> "\n"
  end
end
