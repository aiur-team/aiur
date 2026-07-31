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

  test "renders queued key footer (dependency chip) and active key footer (status dot)" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slot 5 is queued with dependency: "Blocked"
    assert html =~ "Blocked"
    # Non-queued slots render the status dot + progress bar footer
    assert html =~ ~s(class="sd-status-dot")
    assert html =~ ~s(class="sd-progress")
  end

  test "renders priority star, mic indicator, and live segment class" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slots 1 and 4 have priority?: true
    assert html =~ "★"
    # Claude segment always shows the mic dot
    assert html =~ ~s(class="sd-mic")
    # Codex segment is live?: true
    assert html =~ "is-live"
  end

  test "mounts successfully even when Config raises (kind/2 rescue path)" do
    # In the test environment there is no .aiurconfig, so tracker_kind and
    # agent_kind both raise. The rescue branch in kind/2 catches the error and
    # returns the fallback string; if it did not, mount would raise and live/2
    # would return an error tuple rather than {:ok, view, html}.
    assert {:ok, _view, _html} = live(build_conn(), "/streamdeck")
  end

  test "toggle-nav collapses and restore-nav restores the sidebar" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    collapsed = render_click(view, "toggle-nav", %{})
    assert collapsed =~ ~s(data-nav-collapsed="true")

    restored = render_hook(view, "restore-nav", %{"collapsed" => false})
    assert restored =~ ~s(data-nav-collapsed="false")
  end
end
