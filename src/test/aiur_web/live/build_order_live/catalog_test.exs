defmodule AiurWeb.BuildOrderLive.CatalogTest do
  use AiurWeb.BuildOrderLiveCase

  test "epic collapse removes cards and expand restores them", %{source: source, first: first} do
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])
    :ok = FakeDataSource.put_selected(source, selected)
    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    assert has_element?(view, "[data-bo-card]")
    view |> element("button[phx-value-lane='dashboard-ui']") |> render_click()
    refute has_element?(view, "[data-bo-card]")
    assert has_element?(view, "button[phx-value-lane='dashboard-ui'][aria-expanded='false']")
    view |> element("button[phx-value-lane='dashboard-ui']") |> render_click()
    assert has_element?(view, "[data-bo-card]")
  end

  test "a root beyond the read budget displays the truncated count when its selected graph is unavailable", %{source: source, first: first} do
    root = %{root(first, "Large root") | member_count: 501, github_member_count: 501, member_read_count: 100}
    :ok = FakeDataSource.put_catalog(source, catalog_snapshot([root], 1, :healthy))
    :ok = FakeDataSource.put_selected(source, selected_snapshot(first, nil, 1, :unavailable, failure: :member_overflow))
    {:ok, view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ "GitHub graph truncated: 100 of 501 members"
    refute has_element?(view, "[data-bo-card]")
  end

  test "mounts the catalog without demanding any selected root", %{source: source} do
    assert {:ok, _view, html} = live(build_conn(), "/build-orders")

    document = Floki.parse_document!(html)

    assert route_title(document) == "Build Order"
    assert Floki.find(document, "#ax-title a.ax-back") == []

    assert html =~ ~s(data-build-order-status="catalog")
    assert html =~ "bo-catalog-table"
    assert html =~ "Tickets completed"
    assert html =~ ~s(phx-hook="SortableTable")
    assert html =~ "data-sort-client-only"
    assert html =~ "Root forty-two"

    calls = FakeDataSource.calls(source)
    assert {:subscribe_catalog, []} in calls
    assert {:catalog, []} in calls
    assert {:subscribe_sources, []} in calls
    refute Enum.any?(calls, &match?({:demand, _}, &1))
  end

  test "catalog completion and selected estimated work keep distinct labels and values", %{first: first} do
    member = breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)
    catalog_root = progress_root(first, "Root forty-two", progress: 0, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1)

    install_source(
      catalog: catalog_snapshot([catalog_root], 1, :healthy),
      selected: [selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member])],
      sources_loader: fn -> sources_for_member(member.identity, :working, nil, 28) end
    )

    {:ok, catalog_view, catalog_html} = live(build_conn(), "/build-orders")
    assert catalog_html =~ "Tickets completed"
    assert catalog_html |> Floki.parse_document!() |> progress_cell("Root forty-two") |> Floki.text() =~ "0%"
    refute catalog_html =~ "Estimated work progress"

    detail_html = render_patch(catalog_view, "/build-orders/42")

    assert detail_html |> Floki.parse_document!() |> Floki.find(".bo-waves-caption") |> Floki.text() |> String.trim() ==
             "Estimated work progress · complexity weighted"

    assert detail_html =~ "Overall"
    assert detail_html |> Floki.parse_document!() |> Floki.find(".bo-waves-head .bo-wave-seg:first-child .bo-wave-seg-pct") |> Floki.text() |> String.trim() == "28%"
  end

  # #2544: on a repository with no webhooks the catalog only ever republishes
  # what boot deposited, so an operator needs a control that buys the GitHub
  # re-converge — and a held button must not turn into a stream of them.
  test "the catalog page buys a re-converge, and a held button still buys only one", %{source: source} do
    assert {:ok, view, html} = live(build_conn(), "/build-orders")
    assert html =~ ~s(id="build-orders-refresh-catalog")
    assert html =~ ~s(phx-click="refresh-catalog")

    for _click <- 1..3, do: render_click(view, "refresh-catalog")

    calls = FakeDataSource.calls(source)
    assert Enum.count(calls, &(&1 == {:refresh_catalog, []})) == 1
  end

  # The regression this guards is not "a number appears". It is that four
  # different truths about progress used to render as the same glyph, so the
  # page could not report its own failure. Each pair below must differ.
  test "an unresolved pack renders differently from an empty pack in the same table", %{source: source} do
    entries = [
      progress_root(identity(51, "NODE-51"), "Pack that cannot resolve",
        progress: nil,
        progress_resolution: :unresolved,
        member_count: 35
      ),
      progress_root(identity(52, "NODE-52"), "Pack that is genuinely empty",
        progress: 0,
        progress_resolution: :resolved,
        member_count: 0
      ),
      progress_root(identity(53, "NODE-53"), "Pack that is partly resolved",
        progress: 97,
        progress_resolution: :partial,
        progress_resolved_count: 34,
        member_count: 35
      ),
      progress_root(identity(54, "NODE-54"), "Pack with no resolution claim", progress: 91)
    ]

    :ok = FakeDataSource.put_catalog(source, catalog_snapshot(entries, 1, :healthy))

    assert {:ok, _view, html} = live(build_conn(), "/build-orders")
    document = Floki.parse_document!(html)

    unresolved = progress_cell(document, "Pack that cannot resolve")
    empty = progress_cell(document, "Pack that is genuinely empty")
    partial = progress_cell(document, "Pack that is partly resolved")
    unknown = progress_cell(document, "Pack with no resolution claim")

    assert progress_state(unresolved) == "unresolved"
    assert progress_state(empty) == "empty"
    assert progress_state(partial) == "partial"
    assert progress_state(unknown) == "unknown"

    # An operator reads the resolution failure, not a blank and not a zero.
    assert Floki.text(unresolved) =~ "unresolved"
    refute Floki.text(unresolved) =~ "0%"
    refute Floki.text(unresolved) =~ "—"

    # A resolved zero-member pack is empty, not unstarted work at 0%.
    assert Floki.text(empty) =~ "Empty"
    refute Floki.text(empty) =~ "0%"
    refute Floki.text(empty) =~ "unknown"
    assert Floki.find(empty, ~s(.bo-catalog-progress-empty[role="img"])) != []
    assert Floki.find(empty, ".bo-catalog-invalid") == []

    # Partial resolution keeps the number but never hides its coverage.
    assert Floki.text(partial) =~ "97%"
    assert Floki.text(partial) =~ "34/35"

    # Unknown makes no assertion that resolution failed and suppresses the
    # legacy raw number because no source stands behind it.
    assert Floki.text(unknown) =~ "unknown"
    refute Floki.text(unknown) =~ "unresolved"
    refute Floki.text(unknown) =~ "91%"

    # Every rendering is distinguishable from every other one.
    rendered = Enum.map([unresolved, empty, partial, unknown], &Floki.raw_html/1)
    assert length(Enum.uniq(rendered)) == 4
  end

  # "Budget exhausted" alone leaves an operator unable to tell whether to wait a
  # minute or an hour. When the hold carries a reset, the cell names it.
  test "catalog names when an exhausted budget resets", %{source: source} do
    entries = [
      progress_root(identity(57, "NODE-57"), "Pack held by budget", member_count: 35, epic_count: nil, phase_count: nil)
    ]

    snapshot = catalog_snapshot(entries, 1, :healthy)

    data =
      Catalog.put_count_resolution_failure(snapshot.data, :budget, reset_at: ~U[2026-08-23 15:30:00Z])

    :ok = FakeDataSource.put_catalog(source, %{snapshot | data: data})

    assert {:ok, _view, html} = live(build_conn(), "/build-orders")
    document = Floki.parse_document!(html)
    counts = catalog_count_cells(document, "Pack held by budget")

    assert Enum.map(counts, &catalog_count_text/1) == [
             "35",
             "Budget exhausted until 15:30 UTC",
             "Budget exhausted until 15:30 UTC"
           ]

    [_tickets, epics, _waves] = counts
    assert [title] = epics |> Floki.find(".bo-catalog-count-unresolved") |> Floki.attribute("title")
    assert title =~ "It resets at 15:30 UTC."
  end

  # A ticket count comes from the cheap read, so the labelled-read cause does
  # not apply to it — but an unresolved ticket count is still the *same kind* of
  # unknown, and rendering it as a bare "—" while epics said "Unresolved" was
  # the two-renderings-of-one-state defect in miniature (#2250).
  test "an unresolved ticket count renders as unresolved, not a bare dash", %{source: source} do
    entries = [
      progress_root(identity(58, "NODE-58"), "Pack with no ticket count",
        member_count: nil,
        epic_count: nil,
        phase_count: nil
      )
    ]

    snapshot = catalog_snapshot(entries, 1, :healthy)
    :ok = FakeDataSource.put_catalog(source, snapshot)

    assert {:ok, _view, html} = live(build_conn(), "/build-orders")
    document = Floki.parse_document!(html)
    counts = catalog_count_cells(document, "Pack with no ticket count")

    assert Enum.map(counts, &catalog_count_text/1) == ["Unresolved", "Unresolved", "Unresolved"]
    refute Floki.raw_html(counts) =~ "—"
    refute Enum.any?(counts, &(catalog_count_text(&1) == "0"))

    [tickets | _rest] = counts
    assert [marker] = Floki.find(tickets, ".bo-catalog-count-unresolved")
    assert Floki.attribute(marker, "data-count-state") == ["unresolved"]
    assert Floki.attribute(marker, "aria-label") == ["Tickets not counted"]
  end

  test "catalog marks unresolved epic and wave counts without conflating resolved zero", %{source: source} do
    entries = [
      progress_root(identity(55, "NODE-55"), "Pack with unfetched dimensions",
        member_count: 35,
        epic_count: nil,
        phase_count: nil
      ),
      progress_root(identity(56, "NODE-56"), "Pack with no members",
        member_count: 0,
        epic_count: 0,
        phase_count: 0
      )
    ]

    # Every class the projection can establish, each naming its own cause. No
    # entry here collapses a distinct fault into a shared, wrong explanation.
    classified_failures = [
      {:budget, "Budget exhausted", "planning query budget was exhausted"},
      {:rate_limited, "Rate limited", "tracker rate limited the read"},
      {:timeout, "Timed out", "planning request timed out"},
      {:unreachable, "Unreachable", "connection to the tracker was refused or dropped"},
      {:permission, "Not authorized", "tracker credential was missing or rejected"},
      {:schema, "Unreadable response", "tracker response did not match the expected shape"},
      {:incomplete, "Partial read", "read hit Aiur's planning page limit before every member"}
    ]

    rendered_failures =
      Enum.map(classified_failures, fn {failure, visible_text, title_detail} ->
        snapshot = catalog_snapshot(entries, 1, :healthy)
        snapshot = %{snapshot | data: Catalog.put_count_resolution_failure(snapshot.data, failure)}
        :ok = FakeDataSource.put_catalog(source, snapshot)

        assert {:ok, view, html} = live(build_conn(), "/build-orders")
        document = Floki.parse_document!(html)
        unresolved_counts = catalog_count_cells(document, "Pack with unfetched dimensions")
        empty_counts = catalog_count_cells(document, "Pack with no members")
        unresolved_markers = unresolved_counts |> Enum.drop(1) |> Enum.flat_map(&Floki.find(&1, ".bo-catalog-count-unresolved"))

        assert Enum.map(unresolved_counts, &catalog_count_text/1) == ["35", visible_text, visible_text]
        assert Enum.map(empty_counts, &catalog_count_text/1) == ["0", "0", "0"]
        assert Enum.map(unresolved_markers, &Floki.attribute(&1, "data-count-state")) == [["unresolved"], ["unresolved"]]
        assert Enum.map(unresolved_markers, &Floki.attribute(&1, "role")) == [["img"], ["img"]]

        assert Enum.map(unresolved_markers, &Floki.attribute(&1, "aria-label")) == [
                 ["Epics not counted: #{String.downcase(visible_text)}"],
                 ["Waves not counted: #{String.downcase(visible_text)}"]
               ]

        assert [[epics_title], [waves_title]] = Enum.map(unresolved_markers, &Floki.attribute(&1, "title"))
        assert epics_title =~ "Epics could not be counted because the #{title_detail}."
        assert waves_title =~ "Waves could not be counted because the #{title_detail}."

        refute Enum.any?(Enum.drop(unresolved_counts, 1), &(catalog_count_text(&1) == "0"))
        refute Floki.find(unresolved_counts, ".bo-catalog-invalid") != []
        assert Enum.all?(empty_counts, &(Floki.find(&1, "[data-count-state]") == []))
        refute Floki.raw_html(unresolved_counts) =~ "—"
        GenServer.stop(view.pid)

        Enum.map(Enum.drop(unresolved_counts, 1), &Floki.raw_html/1)
      end)

    snapshot = catalog_snapshot(entries, 2, :healthy)
    :ok = FakeDataSource.put_catalog(source, snapshot)
    assert {:ok, _view, generic_html} = live(build_conn(), "/build-orders")
    generic_document = Floki.parse_document!(generic_html)
    generic_counts = catalog_count_cells(generic_document, "Pack with unfetched dimensions")

    assert Enum.map(generic_counts, &catalog_count_text/1) == ["35", "Unresolved", "Unresolved"]

    assert length(Enum.uniq(rendered_failures ++ [Enum.map(Enum.drop(generic_counts, 1), &Floki.raw_html/1)])) ==
             length(classified_failures) + 1
  end

  # The companion to the test above: once a catalog read resolves the label-
  # derived dimensions, the list page shows the same real numbers the detail
  # page does, with no "Unresolved" chip and no unresolved marker anywhere in
  # the row (#1766).
  test "catalog renders resolved epic and wave counts as the numbers they are", %{source: source} do
    entries = [
      progress_root(identity(57, "NODE-57"), "Pack with resolved dimensions",
        member_count: 35,
        epic_count: 4,
        phase_count: 7
      )
    ]

    :ok = FakeDataSource.put_catalog(source, catalog_snapshot(entries, 1, :healthy))

    assert {:ok, _view, html} = live(build_conn(), "/build-orders")
    document = Floki.parse_document!(html)
    counts = catalog_count_cells(document, "Pack with resolved dimensions")

    assert Enum.map(counts, &catalog_count_text/1) == ["35", "4", "7"]
    refute Floki.raw_html(counts) =~ "Unresolved"
    assert Enum.all?(counts, &(Floki.find(&1, "[data-count-state]") == []))
    refute Floki.raw_html(counts) =~ "—"
  end

  defp progress_cell(document, title) do
    document |> catalog_row(title) |> Floki.find("td.bo-catalog-progress-cell")
  end

  defp catalog_count_cells(document, title),
    do: document |> catalog_row(title) |> Floki.find("td.bo-catalog-num")

  defp catalog_count_text(cell), do: cell |> Floki.text() |> String.trim()

  defp catalog_row(document, title) do
    document
    |> Floki.find(".bo-catalog-table tbody tr")
    |> Enum.find(fn row -> Floki.text(row) =~ title end)
    |> tap(&assert(&1, "no catalog row for #{inspect(title)}"))
  end

  defp progress_state(cell) do
    cell
    |> Floki.find("[data-progress-state]")
    |> Floki.attribute("data-progress-state")
    |> List.first()
  end

  defp progress_root(identity, title, attributes) do
    RootSummary.new(
      Map.merge(
        %{
          identity: identity,
          title: title,
          url: "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}",
          state: "OPEN"
        },
        Map.new(attributes)
      )
    )
  end
end
