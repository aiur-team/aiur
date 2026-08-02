defmodule AiurWeb.StreamdeckLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AiurWeb.Endpoint

  @endpoint Endpoint

  setup do
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:aiur, Endpoint, previous_endpoint) end)
    :ok
  end

  test "renders the Stream Deck chassis, eight keys, strip, and knobs" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "Streamdeck+"
    assert html =~ "Stream Deck + control surface"
    assert html =~ ~s(id="sd-keys")
    assert html =~ ~s(id="sd-screen")
    assert html =~ ~s(id="sd-knobs")
    assert length(Regex.scan(~r/data-streamdeck-key=/, html)) == 8
    assert html =~ "Summary"
    assert html =~ "Claude"
    assert html =~ "Codex"
    assert html =~ "Pager"
  end

  test "renders the queued dependency chip and the active status dot footer" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slot 5 is the only queued key and carries dependency: "Blocked".
    assert html =~ "Blocked"
    # Every non-queued, non-empty key renders the status dot + progress footer.
    assert html =~ ~s(class="sd-status-dot")
    assert html =~ ~s(class="sd-progress")
  end

  test "renders the priority star, the mic indicator, and the live segment" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slots 1 and 4 carry priority?: true.
    assert html =~ "★"
    # The Claude segment always shows the mic dot.
    assert html =~ ~s(class="sd-mic")
    # The Codex segment is live?: true.
    assert html =~ "is-live"
  end

  test "the nav icon is a 4x2 key grid, matching the physical device" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    [svg] =
      Regex.run(~r{<svg[^>]*>(?:(?!</svg>).)*?x="2" y="4\.5".*?</svg>}s, html) ||
        flunk("the Stream Deck nav icon svg was not rendered")

    assert length(Regex.scan(~r/<circle /, svg)) == 8,
           "the Stream Deck nav icon must show 8 keys in a 4x2 grid, like the device"
  end

  test "mounts even when Aiur.Config raises, exercising the kind/2 rescue" do
    # There is no .aiurconfig in the test environment, so tracker_kind/0 and
    # agent_kind/0 both raise. The rescue clause in kind/2 swallows that and
    # returns the fallback string; without it, mount/3 would raise and live/2
    # would hand back an error tuple instead of {:ok, view, html}.
    assert {:ok, _view, _html} = live(build_conn(), "/streamdeck")
  end

  test "toggle-nav collapses the sidebar and restore-nav restores it" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    assert render_click(view, "toggle-nav", %{}) =~ ~s(data-nav-collapsed="true")
    assert render_hook(view, "restore-nav", %{"collapsed" => false}) =~ ~s(data-nav-collapsed="false")
  end
end
