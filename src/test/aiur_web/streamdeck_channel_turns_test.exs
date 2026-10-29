defmodule AiurWeb.StreamdeckChannelTurnsTest do
  use Aiur.TestSupport
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.StreamdeckBuildFixture
  alias AiurWeb.Build.ConversationSource
  alias AiurWeb.Build.ConversationSource.Wave0b
  alias AiurWeb.Streamdeck.Deck.Turns

  setup do
    root = Aiur.TestSupport.tmp_root!("deck-turn-keys")
    Aiur.TestSupport.write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    workspace = Path.join([root, "owner", "aiur", "7"])
    File.mkdir_p!(Path.join(workspace, "logs"))
    File.write!(Path.join(workspace, "logs/agent.ndjson"), Enum.map_join(1..30, &line/1))
    snapshot = %{running: [AgentEvents.agent_summary("7", :running, 0, %{title: "Turn paging"})], retrying: [], idle: []}

    put_endpoint_config(
      build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: []}} end,
      streamdeck_snapshot_fun: fn -> snapshot end,
      streamdeck_build_window_fun: fn _, _, _ -> StreamdeckBuildFixture.window(snapshot) end
    )

    previous = Application.fetch_env(:aiur, :build_conversation_source)
    Application.put_env(:aiur, :build_conversation_source, {Wave0b, limit: 7})

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(root)

      case previous do
        {:ok, value} -> Application.put_env(:aiur, :build_conversation_source, value)
        :error -> Application.delete_env(:aiur, :build_conversation_source)
      end
    end)

    :ok
  end

  test "real transcript turns appear on pushed keys, selection scrolls and LIVE restores the newest entry" do
    socket = joined_socket()
    assert_push("frame", _initial, 2_000)
    assert_reply(push(socket, "input", %{"kind" => "key", "index" => 0, "action" => "down"}), :ok, navigation, 2_000)
    refute Map.has_key?(navigation, "frame") or Map.has_key?(navigation, :frame)
    assert_push("chat", %{"id" => "7", "latest" => %{"text" => latest}}, 2_000)
    assert latest =~ "Turn 30"
    assert_push("frame", %{keys: keys, strip: [%{label: newest}]}, 2_000)
    assert Enum.map(keys, & &1.label) == Enum.map(24..30, &text/1) ++ ["LIVE"]
    assert newest =~ "Turn 30"
    refute_received %Phoenix.Socket.Message{event: "logs"}

    assert_reply(push(socket, "input", %{"kind" => "key", "index" => 0, "action" => "down"}), :ok, selected_reply, 2_000)
    refute Map.has_key?(selected_reply, "frame") or Map.has_key?(selected_reply, :frame)
    assert_push("frame", %{strip: [%{label: selected}]}, 2_000)
    assert selected =~ "Turn 24"
    refute selected =~ "Turn 30"
    assert_reply(push(socket, "input", %{"kind" => "dial", "index" => 0, "action" => "turn", "delta" => 1}), :ok, _scroll, 2_000)
    assert_push("frame", %{strip: [%{label: scrolled}]}, 2_000)
    refute scrolled =~ "Turn 24"
    assert scrolled =~ "continuation"

    assert_reply(push(socket, "input", %{"kind" => "dial", "index" => 0, "action" => "turn", "delta" => 32}), :ok, _end, 2_000)
    assert_push("frame", %{strip: [%{label: last_page}]}, 2_000)
    assert last_page =~ "continuation"
    refute last_page == "Conversation ended"

    # Focused physical keys select the turn actually drawn at that slot.
    assert_reply(push(socket, "input", %{"kind" => "key", "index" => 1, "action" => "down"}), :ok, _second, 2_000)
    assert_push("frame", %{strip: [%{label: second_turn}]}, 2_000)
    assert second_turn =~ "Turn 25"
    assert Enum.at(keys, 1).label =~ "Turn 25"

    assert_reply(push(socket, "input", %{"kind" => "key", "index" => 7, "action" => "down"}), :ok, _live, 2_000)
    assert_push("frame", %{strip: [%{label: ^newest}]}, 2_000)
    assert_reply(push(socket, "unfocus", %{}), :ok, _unfocused, 2_000)
    Process.unlink(socket.channel_pid)
    close(socket)
  end

  test "dial paging fetches the opaque desktop cursor and chat_page never repeats the first page" do
    socket = joined_socket()
    assert_push("frame", _initial, 2_000)
    assert_reply(push(socket, "input", %{"kind" => "key", "index" => 0, "action" => "down"}), :ok, _navigation, 2_000)
    assert_push("chat", %{"id" => "7"}, 2_000)
    assert_push("frame", %{keys: first_keys}, 2_000)
    assert Enum.map(first_keys, & &1.label) == Enum.map(24..30, &text/1) ++ ["LIVE"]
    state = :sys.get_state(socket.channel_pid).assigns.deck_chat
    before = state.before
    {:ok, desktop} = ConversationSource.call(state.source, :page, [state.ref, before])
    expected_ids = desktop.entries |> Turns.group() |> Enum.map(& &1.id)

    assert_reply(push(socket, "input", %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => -1}), :ok, _navigation, 2_000)
    assert_push("frame", %{keys: older_keys}, 2_000)
    assert Enum.map(older_keys, & &1.label) == Enum.map(17..23, &text/1) ++ ["LIVE"]

    assert_reply(push(socket, "chat_page", %{"before" => before}), :ok, %{"kind" => "chat-page", "turns" => turns, "more" => true}, 2_000)
    assert Enum.map(turns, & &1["id"]) == expected_ids
    assert Enum.flat_map(turns, & &1["entries"]) |> Enum.map(& &1["id"]) == Enum.map(desktop.entries, & &1.id)
    refute Enum.any?(turns, &(&1["text"] =~ "Turn 24"))
    assert_reply(push(socket, "unfocus", %{}), :ok, _unfocused, 2_000)
    Process.unlink(socket.channel_pid)
    close(socket)
  end

  defp line(n) do
    Jason.encode!(%{
      event: "notification",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      raw: Jason.encode!(%{method: "item/completed", params: %{item: %{id: "message-#{n}", type: "agentMessage", text: text(n)}}})
    }) <> "\n"
  end

  defp text(n), do: "Turn #{n} " <> String.duplicate("continuation ", 70)
end
