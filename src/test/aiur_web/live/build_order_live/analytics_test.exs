defmodule AiurWeb.BuildOrderLive.AnalyticsTest do
  use AiurWeb.BuildOrderLiveCase

  @telemetry_fixtures Path.expand("../../../fixtures/run_telemetry", __DIR__)

  test "the Build Order analytics pane renders under the breakdown and names its scope", %{
    first: first
  } do
    put_telemetry_file(@telemetry_fixtures)

    members = [breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)]

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), members, health(1, :healthy)),
        1,
        :healthy
      )

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected]
    )

    assert {:ok, view, html} = live(build_conn(), "/build-orders/42")

    assert html =~ ">Analytics<"

    assert has_element?(view, ".bo-analytics")
    # The breakdown it sits under is still there.
    assert has_element?(view, "section.bo-breakdown")
  end

  test "a Build Order whose members have never run says so instead of charting zeros", %{
    first: first
  } do
    put_telemetry_file(@telemetry_fixtures)

    # Ticket 7 has no telemetry; the stream itself is perfectly readable.
    members = [breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)]

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), members, health(1, :healthy)),
        1,
        :healthy
      )

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected]
    )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    html = LiveViewAsync.render_when_complete(view)

    assert html =~ "No telemetry for this Build Order yet"
    # A zeroed KPI strip would read as "this build burned nothing".
    refute html =~ "CPU burned"
  end

  test "a Build Order whose members have run renders bounded current-session telemetry", %{
    first: first
  } do
    put_telemetry_file(@telemetry_fixtures)

    # 930 and 931 are the tickets in the two-session telemetry fixture.
    members = [
      breakdown_member(930, phase: 1, lane: "plan-graph", complexity: 3),
      breakdown_member(931, phase: 2, lane: "dashboard-ui", complexity: 4)
    ]

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), members, health(1, :healthy)),
        1,
        :healthy
      )

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected]
    )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    html = LiveViewAsync.render_when_complete(view)

    assert html =~ "Sessions"
    assert html =~ "CPU burned"
    assert html =~ "Member lifecycle"
    assert html =~ "Usage and cost"
    assert html =~ "<svg"

    analytics_html = view |> element(".bo-analytics") |> render()
    assert analytics_html =~ ">#930<"
    refute analytics_html =~ ">#931<"

    refute html =~ "No telemetry for this Build Order yet"
  end

  test "the Build Order's active timeline accepts and resets a shared time domain", %{
    first: first
  } do
    put_telemetry_file(@telemetry_fixtures)

    members = [
      breakdown_member(930, phase: 1, lane: "plan-graph", complexity: 3),
      breakdown_member(931, phase: 2, lane: "dashboard-ui", complexity: 4)
    ]

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), members, health(1, :healthy)),
        1,
        :healthy
      )

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected]
    )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    html = LiveViewAsync.render_when_complete(view)
    [_, start_ms] = Regex.run(~r/data-time-start="(\d+)"/, html)
    [_, end_ms] = Regex.run(~r/data-time-end="(\d+)"/, html)
    start_ms = String.to_integer(start_ms)
    end_ms = String.to_integer(end_ms)
    span = end_ms - start_ms

    zoomed =
      render_hook(view, "time-domain", %{
        "t0" => start_ms + div(span, 4),
        "t1" => end_ms - div(span, 4)
      })

    assert zoomed =~ ~s(class="an-zoombar")
    expected_start = start_ms + div(span, 4)
    expected_end = end_ms - div(span, 4)
    assert length(Regex.scan(~r/data-time-start="#{expected_start}"/, zoomed)) == 5
    assert length(Regex.scan(~r/data-time-end="#{expected_end}"/, zoomed)) == 5

    patched = render_click(view, "toggle-nav", %{})
    assert patched =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="#{expected_start}"/, patched)) == 5
    assert length(Regex.scan(~r/data-time-end="#{expected_end}"/, patched)) == 5

    reset = render_click(view, "reset-time-domain", %{})

    refute reset =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="#{start_ms}"/, reset)) == 5
    assert length(Regex.scan(~r/data-time-end="#{end_ms}"/, reset)) == 5

    full_range = render_hook(view, "time-domain", %{"t0" => start_ms, "t1" => end_ms})
    refute full_range =~ ~s(class="an-zoombar")
  end

  test "an unreadable telemetry stream leaves the rest of the Build Order page intact", %{
    first: first
  } do
    put_telemetry_file("/nonexistent/telemetry.ndjson")

    members = [breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)]

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), members, health(1, :healthy)),
        1,
        :healthy
      )

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected]
    )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    html = LiveViewAsync.render_when_complete(view)

    assert html =~ "No telemetry for this Build Order yet"
    refute render_hook(view, "time-domain", %{"t0" => 1, "t1" => 2}) =~ ~s(class="an-zoombar")
    assert has_element?(view, "#selected-build-order-graph")
    assert has_element?(view, "section.bo-breakdown")
  end

  defp put_telemetry_file(path) do
    previous = Application.get_env(:aiur, :analytics_telemetry_file)
    Application.put_env(:aiur, :analytics_telemetry_file, path)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aiur, :analytics_telemetry_file)
        value -> Application.put_env(:aiur, :analytics_telemetry_file, value)
      end
    end)
  end
end
