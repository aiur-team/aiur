defmodule AiurWeb.StreamdeckLiveChatTest do
  use AiurWeb.StreamdeckLiveCase
  import Phoenix.ChannelTest
  alias Aiur.LiveConversation.Notify
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckLive.Frame

  setup do
    root = Aiur.TestSupport.tmp_root!("emulator-chat")
    Aiur.TestSupport.write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    path = Path.join([root, "owner", "aiur", "1352", "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(path))
    EndpointStubs.put(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: []}} end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, path: path}
  end

  test "emulator and physical input render the same masked retained and appended chat SVG", %{path: path} do
    token = "ghp_" <> String.duplicate("c", 36)
    File.write!(path, line("shared #{token}"))
    socket = AiurWeb.StreamdeckChannelCase.joined_socket()
    assert_push("frame", _initial, 2_000)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    input = %{"kind" => "key", "index" => 0, "action" => "down"}
    assert_reply(push(socket, "input", input), :ok, _reply, 2_000)
    render_hook(view, "input", input)
    assert_push("chat", %{"id" => "1352", "latest" => %{"text" => "shared [REDACTED:ghp]"}}, 2_000)
    assert_push("frame", %{strip: [%{x: 0, width: 800, svg: svg}]} = frame, 2_000)
    assert svg =~ "shared [REDACTED:ghp]"
    refute svg =~ token
    assert eventually(fn -> emulator_strip(view) == frame.strip end)
    assert_dom_svg(view, svg)
    File.write!(path, line("shared appended"), [:append])
    assert_push("frame", %{strip: [%{label: "Conversation ended ● shared appended", svg: appended}]} = frame, 2_000)
    assert eventually(fn -> emulator_strip(view) == frame.strip end)
    assert_dom_svg(view, appended)
    timer = streamdeck_assigns(view).deck_chat.timer
    render_hook(view, "input", %{"kind" => "dial", "index" => 0, "action" => "press"})
    assert eventually(fn -> streamdeck_assigns(view).deck_chat == nil end)
    assert Process.read_timer(timer) == false
    assert_reply(push(socket, "unfocus", %{}), :ok, _reply, 2_000)
  end

  test "emulator refocus, back and terminate release source subscriptions and timers", %{path: path} do
    handle = Notify.random_handle()
    running = %{identifier: "1352", issue_id: "node1352", workspace_path: path |> Path.dirname() |> Path.dirname(), live_conversation: %{generation_handle: handle}}
    EndpointStubs.put(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end)
    File.write!(path, line("subscribed"))
    {:ok, view, _} = live(build_conn(), "/streamdeck")
    render_hook(view, "key-press", %{"identifier" => "1352"})
    topic = Notify.handle_topic(handle)
    pid = view.pid
    assert {^pid, _} = List.keyfind(Registry.lookup(Aiur.PubSub, topic), pid, 0)
    timer = streamdeck_assigns(view).deck_chat.timer
    render_hook(view, "key-press", %{"identifier" => "1350"})
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(timer) == false
    render_hook(view, "key-press", %{"identifier" => "1352"})
    timer = streamdeck_assigns(view).deck_chat.timer
    render_hook(view, "input", %{"kind" => "dial", "index" => 0, "action" => "press"})
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(timer) == false
    render_hook(view, "key-press", %{"identifier" => "1352"})
    timer = streamdeck_assigns(view).deck_chat.timer
    GenServer.stop(pid, :normal)
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(timer) == false
  end

  defp emulator_strip(view), do: view |> streamdeck_assigns() |> Frame.assign_frame() |> Map.fetch!(:frame) |> Map.fetch!(:strip)

  defp assert_dom_svg(view, svg) do
    actual = view |> render() |> Floki.parse_fragment!() |> Floki.find("#sd-screen svg") |> Floki.raw_html()
    assert actual == svg |> Floki.parse_fragment!() |> Floki.raw_html()
  end

  defp line(text) do
    Jason.encode!(%{event: "notification", timestamp: DateTime.to_iso8601(DateTime.utc_now()), raw: Jason.encode!(%{method: "item/completed", params: %{item: %{type: "agentMessage", text: text}}})}) <>
      "\n"
  end
end
