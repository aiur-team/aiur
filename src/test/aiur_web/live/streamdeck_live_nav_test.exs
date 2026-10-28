defmodule AiurWeb.StreamdeckLiveNavTest do
  use AiurWeb.StreamdeckLiveCase

  test "existing emulator events update its own reducer state" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    {:ok, other, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "dial-press", %{"index" => 3, "action" => "cycle-window"})
    assert nav(view).view == :feature
    assert nav(other).view == :ticket
    render_hook(view, "grid-page", %{"page" => 1})
    render_hook(view, "dial-long-press", %{"index" => 3})
    assert nav(view).stack == []
    for _ <- 1..3, do: render_hook(view, "dial-press", %{"index" => 3, "action" => "cycle-window"})
    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert nav(view).selected == "1352"
  end

  test "one legacy dial press cycles without paging the remembered Ticket view" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "grid-page", %{"action" => "cycle"})
    render_hook(view, "dial-press", %{"index" => 3, "action" => "cycle-window"})
    assert nav(view).view == :feature
    assert nav(view).pages.ticket == 0
  end

  test "selection resolves a ticket in an overlapping legacy window", %{snapshot_agent: snapshot} do
    Agent.update(snapshot, fn _ -> fleet_snapshot(9) end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "grid-page", %{"page" => 1})
    assert nav(view).pages.ticket == 1
    render_hook(view, "key-press", %{"identifier" => "fleet-3"})
    assert nav(view).selected == "fleet-3"
    assert :sys.get_state(view.pid).socket.assigns.deck_effects == [{:open_ticket, "fleet-3"}]
  end

  defp nav(view), do: :sys.get_state(view.pid).socket.assigns.deck_nav
end
