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
end
