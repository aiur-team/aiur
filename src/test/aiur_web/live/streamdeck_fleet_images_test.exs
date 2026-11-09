defmodule AiurWeb.StreamdeckFleetImagesTest do
  use AiurWeb.StreamdeckLiveCase
  alias Aiur.TestSupport.EndpointStubs

  test "emulator uses the shared Fleet renderer and physical CI key input" do
    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        {:ok,
         %{
           sources: %{agents: %{state: "ok", observed_at: 123}},
           sections: %{now: [%{num: 17, id: "17", sec: "now", title: "Fleet CI", agent: %{state: "ci_wait"}}], plan: [], nq: []},
           capacity: %{max: nil, stale: false},
           daemon: %{state: "unknown", heartbeat_at: nil}
         }}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    for _ <- 1..3, do: render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "press"})
    assert has_element?(view, "#sd-keys button[data-streamdeck-key='5']", "Waiting for CI")
    assert has_element?(view, "#sd-keys button[data-streamdeck-key='7']", "1 / —")
    html = render_hook(view, "input", %{"kind" => "key", "index" => 5, "action" => "down"})
    assert html =~ "Fleet CI"
    assert has_element?(view, "#sd-keys button[data-streamdeck-key='0']", "Fleet CI")
    assert has_element?(view, "#sd-keys button[data-streamdeck-key='1'][disabled]")
    assert :sys.get_state(view.pid).socket.assigns.deck_nav.stack == [{:fleet, "ci_wait"}]
  end
end
