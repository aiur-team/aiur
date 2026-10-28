defmodule AiurWeb.StreamdeckLiveSettingsTest do
  use AiurWeb.StreamdeckLiveCase

  alias Aiur.LiveConversation.Notify
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.{Settings, SettingsSnapshot}
  alias AiurWeb.Streamdeck.{FrameUpdates, Render}
  alias AiurWeb.StreamdeckLive.Frame

  setup do
    root = Path.join(System.tmp_dir!(), "live-deck-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    EndpointStubs.put(streamdeck_settings_path: path)
    %{path: path}
  end

  test "browser settings keys share the physical model and persist dial-selected brightness", %{path: path} do
    root = Path.dirname(path)
    Aiur.TestSupport.write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    chat_log = Path.join([root, "owner", "aiur", "1352", "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(chat_log))
    File.write!(chat_log, conversation_line("Settings lifecycle"))
    handle = Notify.random_handle()
    running = %{identifier: "1352", issue_id: "node1352", workspace_path: chat_log |> Path.dirname() |> Path.dirname(), live_conversation: %{generation_handle: handle}}
    EndpointStubs.put(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "key-press", %{"identifier" => "1352"})
    chat = streamdeck_assigns(view).deck_chat
    assert chat.ref.id == "1352"
    topic = Notify.handle_topic(handle)
    pid = view.pid
    assert {^pid, _} = List.keyfind(Registry.lookup(Aiur.PubSub, topic), pid, 0)
    html = render_click(view, "command-press", %{"command" => "settings"})
    assert_shared_images(view, html)
    assert streamdeck_assigns(view).deck_nav.surface == :settings
    assert streamdeck_assigns(view).deck_nav.settings.return_surface == :cmd
    assert streamdeck_assigns(view).deck_chat == nil
    assert streamdeck_assigns(view).deck_chat_view == nil
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(chat.timer) == false

    for invalid <- [%{"kind" => "key", "index" => "bad", "action" => "down"}, %{"kind" => "key", "action" => "down"}] do
      render_hook(view, "input", invalid)
      assert :sys.get_state(view.pid).socket.assigns.deck_nav.settings.section == nil
      refute File.exists?(path)
    end

    html = view |> element("#sd-keys button[data-streamdeck-key='2']") |> render_click()
    assert_shared_images(view, html)
    assert :sys.get_state(view.pid).socket.assigns.deck_nav.settings.section == "brightness"
    dial(view, 0, "turn", 3)
    html = dial(view, 0, "press")
    assert_shared_images(view, html)
    assert {:ok, saved} = Settings.read(path)
    assert saved["brightness"] == 30
    assert streamdeck_assigns(view).deck_chat == nil
    assert streamdeck_assigns(view).deck_chat_view == nil
    assert Registry.lookup(Aiur.PubSub, topic) == []
    {:ok, second, _html} = live(build_conn(), "/streamdeck")
    assert :sys.get_state(second.pid).socket.assigns.grid.settings_snapshot.settings["brightness"] == 30
    dial(view, 3, "long_press")
    dial(view, 3, "long_press")
    assert :sys.get_state(view.pid).socket.assigns.deck_nav.surface == :cmd
    reopened = streamdeck_assigns(view).deck_chat
    assert reopened.ref.id == "1352"
    assert {^pid, _} = List.keyfind(Registry.lookup(Aiur.PubSub, topic), pid, 0)
    dial(view, 3, "long_press")
    assert streamdeck_assigns(view).deck_nav.surface == :settings
    assert streamdeck_assigns(view).deck_chat == nil
    assert streamdeck_assigns(view).deck_chat_view == nil
    assert Registry.lookup(Aiur.PubSub, topic) == []
    assert Process.read_timer(reopened.timer) == false
    view |> element("#sd-keys button[data-streamdeck-key='2']") |> render_click()
    dial(view, 0, "turn", 3)
    dial(view, 0, "press")
    assert streamdeck_assigns(view).deck_chat == nil
    assert Registry.lookup(Aiur.PubSub, topic) == []
  end

  test "browser uses reported PC inventory and shows unavailable when its owner disconnects", %{path: path} do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    dial(view, 3, "long_press")
    html = view |> element("#sd-keys button[data-streamdeck-key='0']") |> render_click()
    assert_shared_images(view, html)
    assert :sys.get_state(view.pid).socket.assigns.grid.settings_snapshot.devices == nil
    assert html =~ "Unavailable"

    owner =
      spawn(fn ->
        SettingsSnapshot.devices(%{"mics" => [%{"id" => "pc-mic", "label" => "PC microphone"}], "speakers" => [], "instances" => ["local"]}, path)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    monitor = Process.monitor(owner)
    assert eventually(fn -> SettingsSnapshot.read(path).devices != nil end)
    assert eventually(fn -> :sys.get_state(view.pid).socket.assigns.grid.settings_snapshot.devices != nil end)
    html = render(view)
    assert_shared_images(view, html)
    assert html =~ "PC microphone"
    view |> element("#sd-keys button[data-streamdeck-key='0']") |> render_click()
    assert {:ok, saved} = Settings.read(path)
    assert saved["mic_id"] == "pc-mic"
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    assert eventually(fn -> SettingsSnapshot.read(path).devices == nil end)
    assert eventually(fn -> :sys.get_state(view.pid).socket.assigns.grid.settings_snapshot.devices == nil end)
    html = render(view)
    assert_shared_images(view, html)
    assert :sys.get_state(view.pid).socket.assigns.grid.settings_snapshot.devices == nil
    assert html =~ "Unavailable"
  end

  test "a title-sorted ticket outside the original first page opens and returns to the visible page", %{path: path, snapshot_agent: snapshot_agent} do
    agents = for index <- 0..9, do: fixture_agent(to_string(1000 + index), if(index == 9, do: "Alpha", else: "Zulu #{index}"), "codex")
    Agent.update(snapshot_agent, fn _snapshot -> %{running: agents, retrying: [], idle: []} end)
    assert {:ok, _settings} = Settings.set(%{"default_sort" => "title"}, path)
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assigns = :sys.get_state(view.pid).socket.assigns
    assert Enum.at(assigns.grid.agents, 9).identifier == "1009"
    assert Floki.attribute(Floki.parse_fragment!(html), "#sd-keys button[data-streamdeck-key='0']", "data-streamdeck-identifier") == ["1009"]
    render_hook(view, "key-press", %{"identifier" => "1009"})
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.deck_nav.selected == "1009"
    assert assigns.deck_nav.pages.ticket == 0
    assert assigns.sd_mode == :cmd
    html = dial(view, 0, "press")
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.sd_mode == :grid
    assert assigns.deck_nav.pages.ticket == 0
    assert Floki.attribute(Floki.parse_fragment!(html), "#sd-keys button[data-streamdeck-key='0']", "data-streamdeck-identifier") == ["1009"]
  end

  test "a failed browser save retains the committed value and sets shared failure feedback", %{path: path} do
    assert {:ok, _saved} = Settings.set(%{"brightness" => 30}, path)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    dial(view, 3, "long_press")
    view |> element("#sd-keys button[data-streamdeck-key='2']") |> render_click()
    dial(view, 0, "turn", 8)
    File.chmod!(Path.dirname(path), 0o500)

    try do
      html = dial(view, 0, "press")
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.deck_nav.settings.notice == "Not saved"
      assert assigns.deck_toast == "Not saved"
      assert assigns.grid.settings_snapshot.settings["brightness"] == 30
      assert {:ok, saved} = Settings.read(path)
      assert saved["brightness"] == 30
      assert html =~ "Not saved"
      dial(view, 3, "long_press")
      dial(view, 3, "long_press")
      assert :sys.get_state(view.pid).socket.assigns.deck_toast == nil
    after
      File.chmod!(Path.dirname(path), 0o700)
    end
  end

  defp conversation_line(text) do
    Jason.encode!(%{event: "notification", timestamp: DateTime.to_iso8601(DateTime.utc_now()), raw: Jason.encode!(%{method: "item/completed", params: %{item: %{type: "agentMessage", text: text}}})}) <> "\n"
  end

  defp dial(view, index, action, delta \\ 0), do: render_hook(view, "input", %{"kind" => "dial", "index" => index, "action" => action, "delta" => delta})

  defp assert_shared_images(view, html) do
    assigns = :sys.get_state(view.pid).socket.assigns
    adapted = Frame.assign_frame(assigns)
    {nav, model, expected} = FrameUpdates.frame(assigns.deck_nav, assigns.grid, assigns.usage)
    assert nav == assigns.deck_nav
    assert adapted.frame_model.surface == model.surface
    assert adapted.frame == expected
    assert expected == Render.frame(model)
    buttons = Regex.scan(~r/<button\b[^>]*data-streamdeck-key="\d+"[^>]*>(.*?)<\/button>/s, html)
    assert length(buttons) == 8

    for {[_button, body], image} <- Enum.zip(buttons, expected.keys) do
      if image, do: assert(Floki.raw_html(Floki.parse_fragment!(body)) == Floki.raw_html(Floki.parse_fragment!(image.svg))), else: assert(String.trim(body) == "")
    end
  end
end
