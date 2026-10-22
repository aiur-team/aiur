defmodule AiurWeb.BuildLiveCutoverTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.LiveViewAsync

  test "home and alias render Build while Units remains a hidden rollback" do
    for path <- ["/", "/build"] do
      {:ok, view, _} = live(build_conn(), path)
      LiveViewAsync.render_when_complete(view)
      assert has_element?(view, "#build-root[phx-hook=BuildHome]")
      assert has_element?(view, ~s(a[href="/"][aria-current=page]))
      refute has_element?(view, ".units-card")
      refute has_element?(view, "#units-table")
      refute has_element?(view, ~s(.sidenav-nav a[href="/units"]))
      refute has_element?(view, ~s(.sidenav-nav a[href="/build-orders"]))
    end

    {:ok, view, _} = live(build_conn(), "/units")
    assert has_element?(view, ".units-card")
    refute has_element?(view, ".sidenav-nav [aria-current=page]")
    render_click(view, "select-no-units-filters", %{})
    assert_patch(view, "/units?v=1&scope=none")
    refute has_element?(view, ~s(a[href="/"] .snav-c))
  end

  test "legacy Units filters canonicalize on home" do
    assert {:error, {:live_redirect, %{to: "/?astate=active"}}} = live(build_conn(), "/?v=1&scope=unfinished&conditions=active")
    {:ok, view, _} = live(build_conn(), "/?astate=active")
    assert has_element?(view, "#build-root")
  end

  test "badge follows accepted diffs, hides through resync, and survives Commands refresh" do
    {:ok, view, _} = live(build_conn(), "/")
    LiveViewAsync.render_when_complete(view)
    rows = data()["sections"]["now"]
    active = Enum.filter(rows, &(get_in(&1, ["agent", "state"]) == "active"))
    count = 3
    badge = ~s(a[href="/"] .snav-c)
    assert view |> element(badge) |> render() =~ ">#{count}<"
    row = hd(active) |> put_in(["agent", "state"], "paused")
    send(view.pid, {:build_changes, change(row, 5)})
    assert view |> element(badge) |> render() =~ ">#{count}<"
    send(view.pid, {:build_changes, change(row, 7)})
    assert view |> element(badge) |> render() =~ ">#{count - 1}<"
    send(view.pid, {:decision_changed, "refresh", 1})
    assert view |> element(badge) |> render() =~ ">#{count - 1}<"
    send(view.pid, {:build_changes, change(hd(active), 8)})
    assert view |> element(badge) |> render() =~ ">#{count}<"
    old_history = hd(active) |> Map.merge(%{"sec" => "hist", "status" => "done", "start" => 0, "end" => 1, "agent" => nil})
    send(view.pid, {:build_changes, change(old_history, 9)})
    assert_push_event(view, "build-diff", %{"upsert" => []})
    assert view |> element(badge) |> render() =~ ">#{count - 1}<"
    send(view.pid, {:build_changes, %{resync: true}})
    render(view)
    refute has_element?(view, badge)
    render_hook(view, "build-resync", %{})
    assert_reply(view, %{"kind" => "snapshot"})
    assert view |> element(badge) |> render() =~ ">#{count}<"
  end

  test "unknown pause stays unknown and rejects a forged toggle on home and Units" do
    Phoenix.Config.put(AiurWeb.Endpoint, :orchestrator, :cutover_missing_orchestrator)
    # An adopted endpoint can carry another test's read-only mode, which refuses before the unknown check.
    previous_writable = AiurWeb.Endpoint.config(:dashboard_writable)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, true)

    on_exit(fn ->
      if Process.whereis(AiurWeb.Endpoint), do: Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, previous_writable)
    end)

    for path <- ["/", "/units"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "#ax-pause[disabled]")
      assert render(view) =~ "Pause state unknown"
      render_hook(view, "toggle-global-pause", %{})
      assert view |> element(".global-pause-error") |> render() =~ "Global pause state is unknown; refresh and retry."
    end
  end

  test "home rechecks writable mode on forged pause events" do
    {:ok, view, _} = live(build_conn(), "/")
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    render_hook(view, "toggle-global-pause", %{})
    assert has_element?(view, "#ax-pause[disabled][aria-disabled=true]")
    assert :sys.get_state(view.pid).socket.assigns.writable == false
  end

  test "loading and unavailable home do not fabricate an active count" do
    html = build_conn() |> get("/") |> html_response(200)
    assert html =~ "Loading build timeline"
    refute html =~ ~s(class="snav-c")
    source(mode: :error)
    {:ok, view, _} = live(build_conn(), "/")
    LiveViewAsync.render_when_complete(view)
    assert has_element?(view, "#build-root[data-build-state=unavailable]")
    refute has_element?(view, ~s(a[href="/"] .snav-c))
  end
end
