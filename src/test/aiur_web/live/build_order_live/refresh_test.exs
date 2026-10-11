defmodule AiurWeb.BuildOrderLive.RefreshTest do
  use AiurWeb.BuildOrderLiveCase

  test "a UI-only tick re-derives from the display clock without polling providers" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    clock = start_supervised!({Agent, fn -> observed_at end})
    Application.put_env(:aiur, :build_order_display_clock, fn -> Agent.get(clock, & &1) end)

    catalog =
      []
      |> catalog_snapshot(1, :healthy)
      |> put_in([Access.key(:health)], health(1, :healthy, observed_at: observed_at))

    source = install_source(catalog: catalog)
    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    render_async(view, 2_000)

    calls_before_tick = FakeDataSource.calls(source)

    Agent.update(clock, &DateTime.add(&1, 7, :second))
    send(view.pid, :build_order_ui_tick)
    _advanced = render(view)

    # The invariant is that a display-only tick re-derives from the assigned
    # clock without touching the data source. It previously also asserted the
    # topbar clock advanced; that clock has been removed, and the catalog route
    # renders no other absolute time, so only the no-polling guard remains.
    assert Runtime.display_now() == DateTime.add(observed_at, 7, :second)
    assert FakeDataSource.calls(source) == calls_before_tick
  end

  test "distinguishes cold, unavailable, and stale-LKG catalog states" do
    cold = install_source(catalog: nil)
    assert {:ok, cold_view, cold_html} = live(build_conn(), "/build-orders")
    assert cold_html =~ ~s(data-build-order-catalog-state="loading")
    assert cold_html =~ "Loading Build Orders"
    GenServer.stop(cold_view.pid)
    assert Process.alive?(cold)

    unavailable = install_source(catalog: catalog_snapshot(nil, :unknown, :unavailable))
    assert {:ok, unavailable_view, unavailable_html} = live(build_conn(), "/build-orders")
    assert unavailable_html =~ ~s(data-build-order-catalog-state="unavailable")
    assert unavailable_html =~ "No Build Order list"
    GenServer.stop(unavailable_view.pid)
    assert Process.alive?(unavailable)

    identity = identity(42, "NODE-42")
    stale = install_source(catalog: catalog_snapshot([root(identity, "Stale root")], 1, :stale))
    assert {:ok, _view, stale_html} = live(build_conn(), "/build-orders")
    assert stale_html =~ ~s(data-build-order-catalog-state="stale_lkg")
    assert stale_html =~ ~s(href="/build-orders/42")
    assert Process.alive?(stale)

    empty = install_source(catalog: catalog_snapshot([], 2, :healthy))
    assert {:ok, _view, empty_html} = live(build_conn(), "/build-orders")
    assert empty_html =~ ~s(data-build-order-catalog-state="empty")
    assert empty_html =~ "No Build Orders for this repository"
    assert Process.alive?(empty)
  end

  test "an empty catalog names the directories it searched" do
    catalog = catalog_snapshot([], 1, :healthy)
    catalog = put_in(catalog.data.search_paths, [".aiur/build_orders", "/var/lib/aiur/builds"])
    _source = install_source(catalog: catalog)

    assert {:ok, _view, html} = live(build_conn(), "/build-orders")
    assert html =~ "Searched:"
    assert html =~ ".aiur/build_orders"
    assert html =~ "/var/lib/aiur/builds"
  end

  test "deep links resolve through the catalog and subscribe before one demand", %{
    source: source,
    first: first
  } do
    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")

    document = Floki.parse_document!(html)

    assert route_title(document) == "Build Order #42"
    assert length(Regex.scan(~r/#42/, Floki.text(document))) == 1
    assert Floki.find(document, ".bo-page-header") == []

    assert [back_link] = Floki.find(document, ~s(#ax-title a.ax-back[aria-label="Back to all Build Orders"]))
    assert Floki.attribute(back_link, "href") == ["/build-orders"]

    assert html =~ ~s(data-build-order-root="42")
    assert html =~ "Valid empty graph"
    assert selected_lede(document) == "Root forty-two"
    refute html =~ ~s(data-layout-node)

    calls = FakeDataSource.calls(source)
    subscribe_index = call_index(calls, {:subscribe_selected, [first]})
    demand_index = call_index(calls, {:demand, [first]})

    assert subscribe_index < demand_index
    assert Enum.count(calls, &(&1 == {:demand, [first]})) == 1
    refute Enum.any?(calls, &match?({:selected, _}, &1))
  end

  test "a cold selected root buys an immediate refresh instead of waiting for the catalog cycle", %{
    first: first
  } do
    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        # A root nobody has ever read: demand returns a nil-data snapshot.
        selected: [selected_snapshot(first, nil, 1, :healthy)]
      )

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ ~s(data-build-order-status="selected_loading")

    calls = FakeDataSource.calls(source)
    demand_index = call_index(calls, {:demand, [first]})
    refresh_index = call_index(calls, {:refresh, [first]})

    assert demand_index != nil
    assert refresh_index != nil
    assert refresh_index > demand_index
  end

  test "a healthy complete catalog distinguishes not-found from unavailable", %{first: first} do
    source =
      install_source(catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy))

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/99")
    assert html =~ ~s(data-build-order-status="not_found")
    assert html =~ "Build Order not found"
    refute Enum.any?(FakeDataSource.calls(source), &match?({:demand, _}, &1))
  end

  test "malformed root parameters fail closed without a demand", %{source: source} do
    assert {:ok, _view, html} = live(build_conn(), "/build-orders/01")
    document = Floki.parse_document!(html)

    assert html =~ ~s(data-build-order-status="invalid_parameter")
    assert html =~ "Invalid Build Order URL"
    assert route_title(document) == "Build Order"

    assert [back_link] = Floki.find(document, ~s(#ax-title a.ax-back[aria-label="Back to all Build Orders"]))
    assert Floki.attribute(back_link, "href") == ["/build-orders"]

    refute Enum.any?(FakeDataSource.calls(source), &match?({:demand, _}, &1))
  end
end
