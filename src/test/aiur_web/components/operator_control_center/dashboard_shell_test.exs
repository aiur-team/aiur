defmodule AiurWeb.OperatorControlCenter.DashboardShellTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, Overview, RouteRegistry}

  defp shell(opts \\ []) do
    action = Keyword.get(opts, :action, :index)
    assigns = %{route: RouteRegistry.current_route(action), routes: RouteRegistry.routes(%{}), tracker_kind: "github", agent_kind: "codex", inner_block: []}

    render_component(&DashboardShell.dashboard_shell/1, Map.merge(assigns, Map.new(Keyword.delete(opts, :action))))
    |> Floki.parse_document!()
  end

  test "shell renders the settings menu, heading and single navigation" do
    doc = shell()
    assert length(Floki.find(doc, "header.ax-top .ax-brand #ax-set #ax-menu[role=menu][inert]")) == 1
    assert Floki.find(doc, "#ax-menu > button") |> Floki.attribute("id") == ["ax-pause", "theme-toggle", "ax-palette"]
    assert Floki.find(doc, "#route-title[role=heading][aria-level='1']") |> Floki.text() == "Units"
    assert length(Floki.find(doc, "section.dashboard-shell[aria-labelledby=route-title]")) == 1
    assert length(Floki.find(doc, "nav.sidenav-nav")) == 1
    assert Floki.find(doc, ".shell-nav-mobile, #nav-toggle, .route-context") == []
    assert Floki.attribute(Floki.find(doc, "#ax-drag"), "data-nav-collapsed") == ["false"]
  end

  test "unknown pause is disabled without claiming a boolean state" do
    doc = shell(globally_paused: nil, writable: true)
    item = Floki.find(doc, "#ax-pause")
    assert Floki.text(item) =~ "Pause state unknown"
    assert Floki.attribute(item, "disabled") == ["disabled"]
    assert Floki.attribute(item, "aria-checked") == []
    assert Floki.attribute(item, "role") == ["menuitem"]
    assert Floki.find(item, ".ax-sw") == []
    assert Floki.find(doc, "#ax-paused.show") == []
    assert Floki.attribute(item, "title") == ["The daemon's pause state is not available"]
  end

  test "known pause state keeps the writable gate and paused chip" do
    readonly = shell(globally_paused: false, writable: false) |> Floki.find("#ax-pause")
    assert Floki.attribute(readonly, "disabled") == ["disabled"]
    assert Floki.attribute(readonly, "aria-disabled") == ["true"]
    assert Floki.attribute(readonly, "title") == ["Read-only dashboard: pausing is unavailable"]
    assert Floki.attribute(readonly, "aria-checked") == ["false"]
    paused = shell(globally_paused: true, writable: true)
    assert Floki.attribute(Floki.find(paused, "#ax-pause"), "disabled") == []
    assert Floki.attribute(Floki.find(paused, "#ax-pause"), "aria-checked") == ["true"]
    assert Floki.text(Floki.find(paused, "#ax-paused.show")) == "All agents paused"
  end

  test "known zero and absent navigation counts remain distinct" do
    assert shell(nav_counts: %{units: 0}) |> Floki.find("a[href='/'] .snav-c") |> Floki.text() == "0"
    assert shell() |> Floki.find(".snav-c") == []
    assert shell(nav_counts: %{commands: 0}) |> Floki.find("a[href='/commands'] .snav-c") == []
    doc = shell(nav_counts: %{commands: 3})
    assert Floki.text(Floki.find(doc, ".snav-c.attn[title='3 need a command']")) == "3"
    assert Floki.text(Floki.find(doc, "a[href='/commands'] .sr-only")) == ", 3 need a command"
  end

  test "unknown command counts omit the dot and preserve the unavailable notice" do
    doc = shell(nav_counts: %{commands: nil})
    assert Floki.find(doc, "a[href='/commands'] .snav-c") == []
    banner = render_component(&Overview.decisions_banner/1, %{retained_counts: %{awaiting: nil, awaiting_blocking: nil, health: %{status: :unavailable}}})
    assert banner =~ "Command counts unavailable"
    refute banner =~ ~s(id="decisions-banner")
  end

  test "Streamdeck keeps its page title and uses the six-dot design navigation icon" do
    doc = shell(action: :streamdeck)
    assert Floki.text(Floki.find(doc, "#route-title")) == "Streamdeck+"
    assert Floki.text(Floki.find(doc, "a[href='/streamdeck'] .snav-label")) == "Streamdeck"
    assert length(Floki.find(doc, "a[href='/streamdeck'] svg circle")) == 6
    assert Floki.attribute(Floki.find(doc, "a[href='/streamdeck'] svg"), "stroke-linecap") == []
  end

  test "back link stays in the top bar when page heads are hidden" do
    doc = shell(back_path: "/build-orders", back_label: "Back to all Build Orders")
    assert Floki.attribute(Floki.find(doc, "#ax-title a.ax-back"), "href") == ["/build-orders"]
    assert Floki.attribute(Floki.find(doc, "#ax-title a.ax-back"), "aria-label") == ["Back to all Build Orders"]
  end

  test "future regression guard: invalid stored collapse leaves server state unchanged" do
    socket = %Phoenix.LiveView.Socket{} |> NavState.assign_nav()
    assert NavState.restore(socket, "x").assigns.nav_collapsed == false
  end

  test "future regression guard: navigation has no Khala item" do
    refute shell() |> Floki.find(".snav-label") |> Floki.text() =~ "Khala"
    refute Enum.any?(RouteRegistry.routes(%{}), &(&1.id == :khala))
  end
end
