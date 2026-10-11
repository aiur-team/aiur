defmodule AiurWeb.BuildOrderLive.PatchingTest do
  use AiurWeb.BuildOrderLiveCase

  # The consolidated header states only "Build Order #<n>". Without this lede a
  # bookmarked detail page never names the root, and the graph heading is
  # sr-only boilerplate, so nothing on the surface identifies what you opened.
  test "a resolved detail page names its root", %{first: first} do
    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected_snapshot(first, "Release dashboard", 1, :healthy, members: [member(7)])]
    )

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")
    document = Floki.parse_document!(html)

    assert route_title(document) == "Build Order #42"
    assert selected_lede(document) == "Release dashboard"
  end

  test "a leading BO: tag is dropped from the dashboard title lede", %{first: first} do
    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected_snapshot(first, "BO: Stream Deck Parity", 1, :healthy, members: [member(7)])]
    )

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")
    assert selected_lede(Floki.parse_document!(html)) == "Stream Deck Parity"
  end

  test "marks a selected root unavailable when its initial demand fails", %{first: first} do
    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: []
      )

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ ~s(data-build-order-status="selected_unavailable")
    assert html =~ "Could not read the plan"
    assert html =~ "Investigate why Build Order #42&#39;s plan could not be read."
    assert html =~ "`provider_unavailable`"
    refute html =~ "Build Order graph summary"
    refute html =~ "Plan distribution"
    refute html =~ "Analytics unavailable"
    refute html =~ "Usage and cost unavailable"
    # #1792: an unresolved root has no name to state, and the collapsed failure
    # card must not resurrect one.
    assert Floki.parse_document!(html) |> selected_lede() == nil
    assert {:demand, [first]} in FakeDataSource.calls(source)
  end

  test "renders the epic breakdown on the selected route", %{first: first} do
    members = [
      breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3),
      breakdown_member(8, phase: 2, lane: "dashboard-ui", complexity: 4)
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

    assert {:ok, view, html} = live(build_conn(), "/build-orders/42")

    # The breakdown region is now epics-only, each row with a coloured icon and bar.
    assert html =~ ~s(<section class="bo-breakdown")
    assert html =~ ">Epics<"
    assert has_element?(view, ".bo-breakdown-list .bo-breakdown-row .bo-breakdown-row-name")
    assert has_element?(view, ".bo-breakdown-row .bo-breakdown-row-ic")
    assert has_element?(view, ".bo-breakdown-row-bar")

    # Plan-distribution stats, the phase block, and ad hoc are gone.
    refute has_element?(view, "#bo-phase-breakdown")
    refute has_element?(view, "dl.bo-kpis")
    refute html =~ "Ad Hoc epic"

    # The graph surface remains present and unaffected alongside the breakdown.
    assert has_element?(view, "#selected-build-order-graph")
  end

  test "reloads sources when an ad hoc overlay update arrives", %{first: first} do
    members = [breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)]

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), members, health(1, :healthy)),
        1,
        :healthy
      )

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected],
        sources_loader: fn -> sources_with_adhoc(adhoc_source_snapshot()) end
      )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    loads_before = Enum.count(FakeDataSource.calls(source), &match?({:load_sources, []}, &1))

    send(view.pid, {:build_order_adhoc_updated, adhoc_source_snapshot()})
    _ = render(view)

    loads_after = Enum.count(FakeDataSource.calls(source), &match?({:load_sources, []}, &1))
    assert loads_after > loads_before
  end

  test "patches a member from the live agent projection without a page refresh", %{first: first} do
    member = breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), [member], health(1, :healthy)),
        1,
        :healthy
      )

    sources =
      start_supervised!({Agent, fn -> sources_for_member(member.identity, :working, nil, 30) end})

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected],
      sources_loader: fn -> Agent.get(sources, & &1) end
    )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    LiveViewAsync.render_after_refresh(view)
    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="working"]), "agent live")
    assert has_element?(view, ~s([data-bo-card="7"]), "30%")

    Agent.update(sources, fn _sources ->
      sources_for_member(member.identity, :paused, :operator_pause, 45)
    end)

    :ok = AgentPubSub.broadcast_running_change([])

    LiveViewAsync.render_after_refresh(view)
    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="plain"]), "Paused")
    assert has_element?(view, ~s([data-bo-card="7"]), "45%")

    Agent.update(sources, fn _sources -> sources_for_ci_wait_member(member.identity, 60) end)
    :ok = AgentPubSub.broadcast_running_change([])

    LiveViewAsync.render_after_refresh(view)
    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="plain"]), "CI waiting")
    assert has_element?(view, ~s([data-bo-card="7"]), "60%")
  end

  # The Khala report: a paused member's last check-in said 80%, its activity
  # row is now stale, and the graph card, wave bar, and overall bar all showed
  # 0% while the lower breakdown still showed the work. The value behind the
  # rendering must be the retained percent, tagged last known with its age —
  # never a confident zero and never dressed as a live reading.
  test "a paused member's stale reading renders as last known on the card, wave, and overall bars", %{first: first} do
    member = breakdown_member(7, phase: 1, lane: "plan-graph", complexity: 3)

    selected =
      selected_snapshot(
        first,
        SelectedRoot.new(root(first, "Root forty-two"), [member], health(1, :healthy)),
        1,
        :healthy
      )

    install_source(
      catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
      selected: [selected],
      sources_loader: fn -> sources_for_stale_paused_member(member.identity, 80) end
    )

    assert {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    render_async(view, 2_000)

    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="plain"]), "Paused")
    assert has_element?(view, ~s([data-bo-card="7"] .bo-node-pct[data-progress-state="resolved"][data-progress-freshness="last_known"]), "80%")
    assert view |> render() |> Floki.parse_document!() |> Floki.find(~s([data-bo-card="7"] .bo-node-pct)) |> Floki.text() |> String.trim() == "80%"
    assert has_element?(view, ~s([data-bo-card="7"] .bo-node-note), "last known")
    assert has_element?(view, ~s([data-bo-card="7"] .bo-node-note), "d ago")

    # The wave and overall bars fold the same retained percent and carry the
    # same marker; the lower breakdown row agrees.
    document = view |> render() |> Floki.parse_document!()
    [overall | waves] = Floki.find(document, ".bo-waves-head .bo-wave-seg")

    for segment <- [overall | waves] do
      assert Floki.attribute(segment, "data-progress-freshness") == ["last_known"]
      assert segment |> Floki.find(".bo-wave-seg-pct") |> Floki.text() |> String.trim() == "80%"
      assert segment |> Floki.find(".bo-wave-seg-note") |> Floki.text() =~ "last known"
    end

    # The epic column header carries the same percent, marker, and age.
    assert [epic] = Floki.find(document, ~s(.bo-epic[data-progress-freshness="last_known"]))
    assert epic |> Floki.find(~s(.bo-epic-count[data-progress-freshness="last_known"])) |> Floki.text() |> String.trim() == "80%"
    assert epic |> Floki.find(".bo-epic-note") |> Floki.text() =~ ~r/last known \d+d ago/

    assert [row] = Floki.find(document, ~s(.bo-breakdown-row[data-breakdown-key="1"]))
    assert Floki.attribute(row, "data-breakdown-progress") == ["80"]
    assert Floki.attribute(row, "data-breakdown-last-known") == ["1"]
  end

  test "projection reset rolls the catalog subscription to the replacement repository", %{
    source: source
  } do
    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    replacement_repository = {"new-owner", "new-repo"}
    replacement = identity(52, "NEW-52", replacement_repository)

    :ok =
      FakeDataSource.put_catalog(
        source,
        catalog_snapshot(
          [root(replacement, "Replacement root")],
          1,
          :healthy,
          replacement_repository,
          2
        )
      )

    send(view.pid, {:graph_projection_reset, 2})
    assert render(view) =~ "Replacement root"

    calls = FakeDataSource.calls(source)
    unsubscribe_index = call_index(calls, {:unsubscribe_catalog, [repository()]})
    resubscribe_index = call_index_after(calls, {:subscribe_catalog, []}, unsubscribe_index)
    reload_index = call_index_after(calls, {:catalog, []}, resubscribe_index)
    assert unsubscribe_index < resubscribe_index
    assert resubscribe_index < reload_index

    publication =
      catalog_snapshot(
        [root(replacement, "Replacement root updated")],
        2,
        :healthy,
        replacement_repository,
        2
      )

    send(view.pid, {:graph_projection_generation, publication})
    assert render(view) =~ "Replacement root updated"

    :ok =
      FakeDataSource.put_catalog(
        source,
        catalog_snapshot(
          [root(replacement, "Restarted projection root")],
          1,
          :healthy,
          replacement_repository,
          3
        )
      )

    send(view.pid, {:graph_projection_reset, 3})
    assert render(view) =~ "Restarted projection root"
  end

  test "reset authority rejects queued old-instance catalog and selected publications", %{
    source: source,
    first: first
  } do
    assert {:ok, view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ "Build Order #42"

    new_catalog =
      catalog_snapshot([root(first, "New-instance root")], 1, :healthy, repository(), 2)

    new_selected =
      selected_snapshot(first, "New-instance generation one", 1, :healthy,
        authority_epoch: 2,
        members: [member(70)]
      )

    :ok = FakeDataSource.put_catalog(source, new_catalog)
    :ok = FakeDataSource.put_selected(source, new_selected)

    send(view.pid, {:graph_projection_reset, 2})
    assert render(view) =~ "Ticket 70"

    old_catalog =
      catalog_snapshot([root(first, "Queued old catalog")], 99, :healthy, repository(), 1)

    old_selected =
      selected_snapshot(first, "Queued old selected root", 99, :healthy,
        authority_epoch: 1,
        members: [member(71)]
      )

    send(view.pid, {:graph_projection_generation, old_catalog})
    send(view.pid, {:graph_projection_generation, old_selected})

    final_html = render(view)
    assert final_html =~ "Ticket 70"
    refute final_html =~ "Queued old catalog"
    refute final_html =~ "Ticket 71"
  end

  defp call_index_after(calls, expected, index) do
    calls
    |> Enum.with_index()
    |> Enum.find_value(fn {call, call_index} ->
      if call == expected and call_index > index, do: call_index
    end)
    |> case do
      nil -> flunk("missing source call #{inspect(expected)} after #{index} in #{inspect(calls)}")
      call_index -> call_index
    end
  end

  defp sources_with_adhoc(adhoc) do
    %{
      execution: %{running: [], retrying: [], idle: []},
      activity: %{generation: 1, entries: []},
      adhoc: adhoc
    }
  end

  defp sources_for_ci_wait_member(identity, progress) do
    sources_for_member(identity, :idle, nil, progress)
    |> put_in([:execution, :running], [])
    |> put_in([:execution, :idle], [
      %{tracker_identity: identity, waiting_reason: :waiting_for_ci}
    ])
  end

  # A paused member whose activity row and reading both went stale: the
  # projection's freshness after an agent stops emitting.
  defp sources_for_stale_paused_member(identity, progress) do
    sources_for_member(identity, :paused, :operator_pause, progress)
    |> update_in([:activity, :entries], fn [entry] ->
      [entry |> Map.put(:status, :stale) |> put_in([:progress, :freshness], :stale) |> put_in([:stage, :freshness], :stale)]
    end)
  end

  defp adhoc_source_snapshot do
    %AdHocSnapshot{
      status: :available,
      generation: 1,
      observed_at: ~U[2026-07-15 12:00:00Z],
      members: [
        %{
          identity: identity(9001, "NODE-9001"),
          identifier: "9001",
          title: "Ad hoc fix",
          url: "https://github.com/owner/repo/issues/9001",
          lifecycle: :open,
          labels: ["build-lane:adhoc", "phase:1"]
        }
      ]
    }
  end
end
