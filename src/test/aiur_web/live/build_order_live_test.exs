defmodule AiurWeb.BuildOrderLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.{AgentPubSub, TrackerIdentity}
  alias Aiur.TestSupport.AwaitingCommands

  alias Aiur.BuildOrder.AdHocSource.Snapshot, as: AdHocSnapshot
  alias Aiur.BuildOrder.{Catalog, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.TicketDetail.Snapshot, as: DetailSnapshot
  alias Aiur.BuildOrder.TicketDetail.State
  alias Aiur.BuildOrder.TicketHistory
  alias AiurWeb.BuildOrder.Runtime
  alias AiurWeb.Endpoint

  @endpoint Endpoint
  @telemetry_fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

  defmodule FakeDataSource do
    use GenServer

    alias Aiur.BuildOrder.GraphProjection.Snapshot

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def calls(server), do: GenServer.call(server, :calls)
    def put_catalog(server, catalog), do: GenServer.call(server, {:put_catalog, catalog})
    def put_selected(server, selected), do: GenServer.call(server, {:put_selected, selected})

    def subscribe_catalog(server), do: invoke(server, :subscribe_catalog, [])

    def unsubscribe_catalog(server, repository),
      do: invoke(server, :unsubscribe_catalog, [repository])

    def catalog(server), do: invoke(server, :catalog, [])

    def subscribe_sources(server) do
      :ok = Aiur.AgentPubSub.subscribe_running()
      invoke(server, :subscribe_sources, [])
    end

    def load_sources(server) do
      loader = invoke(server, :load_sources, [])
      loader.()
    end

    def subscribe_selected(server, identity), do: invoke(server, :subscribe_selected, [identity])

    def unsubscribe_selected(server, identity),
      do: invoke(server, :unsubscribe_selected, [identity])

    def selected(server, identity), do: invoke(server, :selected, [identity])
    def demand(server, identity), do: invoke(server, :demand, [identity])
    def release(server, identity), do: invoke(server, :release, [identity])
    def subscribe_context(server, identity), do: invoke(server, :subscribe_context, [identity])

    def unsubscribe_context(server, identity),
      do: invoke(server, :unsubscribe_context, [identity])

    def load_context(server, identity) do
      loader = invoke(server, :load_context, [identity])
      loader.(identity)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         report: Keyword.fetch!(opts, :report),
         catalog: Keyword.fetch!(opts, :catalog),
         selected: Map.new(Keyword.get(opts, :selected, []), &{&1.scope, &1}),
         sources:
           Keyword.get(opts, :sources, %{
             execution: %{running: [], retrying: [], idle: []},
             activity: %{generation: 1, entries: []}
           }),
         sources_loader:
           Keyword.get(opts, :sources_loader, fn ->
             Keyword.get(opts, :sources, %{
               execution: %{running: [], retrying: [], idle: []},
               activity: %{generation: 1, entries: []}
             })
           end),
         context_loader:
           Keyword.get(opts, :context_loader, fn _identity ->
             %{detail: {:error, :unavailable}, history: {:error, :unavailable}}
           end),
         calls: []
       }}
    end

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:put_catalog, catalog}, _from, state),
      do: {:reply, :ok, %{state | catalog: catalog}}

    def handle_call({:put_selected, %Snapshot{scope: scope} = selected}, _from, state),
      do: {:reply, :ok, %{state | selected: Map.put(state.selected, scope, selected)}}

    def handle_call({:invoke, name, args}, _from, state) do
      call = {name, args}
      send(state.report, {:build_order_source_call, call})
      {:reply, reply(name, args, state), %{state | calls: [call | state.calls]}}
    end

    defp invoke(server, name, args), do: GenServer.call(server, {:invoke, name, args})
    defp reply(:subscribe_catalog, [], _state), do: :ok
    defp reply(:unsubscribe_catalog, [_repository], _state), do: :ok
    defp reply(:catalog, [], state), do: state.catalog
    defp reply(:subscribe_sources, [], _state), do: :ok
    defp reply(:load_sources, [], state), do: state.sources_loader
    defp reply(:subscribe_selected, [_identity], _state), do: :ok
    defp reply(:unsubscribe_selected, [_identity], _state), do: :ok
    defp reply(:selected, [identity], state), do: selected_reply(state, identity)
    defp reply(:demand, [identity], state), do: selected_reply(state, identity)
    defp reply(:release, [_identity], _state), do: :ok
    defp reply(:subscribe_context, [_identity], _state), do: :ok
    defp reply(:unsubscribe_context, [_identity], _state), do: :ok
    defp reply(:load_context, [_identity], state), do: state.context_loader

    defp selected_reply(state, identity) do
      case Map.fetch(state.selected, {:selected, identity}) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :unavailable}
      end
    end
  end

  setup context do
    first = identity(42, "NODE-42")
    second = identity(43, "NODE-43")

    catalog =
      catalog_snapshot(
        [root(first, "Root forty-two"), root(second, "Root forty-three")],
        1,
        :healthy
      )

    source =
      start_supervised!(
        {FakeDataSource,
         report: self(),
         catalog: catalog,
         selected: [
           selected_snapshot(first, "Root forty-two", 1, :healthy),
           selected_snapshot(second, "Root forty-three", 1, :healthy)
         ]}
      )

    previous_source = Application.get_env(:aiur, :build_order_data_source)
    previous_clock = Application.get_env(:aiur, :build_order_display_clock)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, :build_order_data_source, {FakeDataSource, source})

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false
      )
      |> Keyword.merge(awaiting_commands_config(context))

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      restore_application_env(:build_order_data_source, previous_source)
      restore_application_env(:build_order_display_clock, previous_clock)
      restore_application_env(Endpoint, previous_endpoint)
    end)

    %{source: source, first: first, second: second}
  end

  test "mounts the catalog without demanding any selected root", %{source: source} do
    assert {:ok, _view, html} = live(build_conn(), "/build-orders")

    assert Floki.parse_document!(html) |> Floki.find("h1#route-title") |> Floki.text() =~
             "Build Order"

    assert html =~ ~s(data-build-order-status="catalog")
    assert html =~ "bo-catalog-table"
    assert html =~ "Root forty-two"

    calls = FakeDataSource.calls(source)
    assert {:subscribe_catalog, []} in calls
    assert {:catalog, []} in calls
    assert {:subscribe_sources, []} in calls
    refute Enum.any?(calls, &match?({:demand, _}, &1))
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
    assert progress_state(empty) == "resolved"
    assert progress_state(partial) == "partial"
    assert progress_state(unknown) == "unknown"

    # An operator reads the resolution failure, not a blank and not a zero.
    assert Floki.text(unresolved) =~ "unresolved"
    refute Floki.text(unresolved) =~ "0%"
    refute Floki.text(unresolved) =~ "—"

    # The empty pack is a real, resolved zero.
    assert Floki.text(empty) =~ "0%"
    refute Floki.text(empty) =~ "unknown"

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

    :ok = FakeDataSource.put_catalog(source, catalog_snapshot(entries, 1, :healthy))

    assert {:ok, _view, html} = live(build_conn(), "/build-orders")
    document = Floki.parse_document!(html)

    unresolved_counts = catalog_count_cells(document, "Pack with unfetched dimensions")
    empty_counts = catalog_count_cells(document, "Pack with no members")

    assert Enum.map(unresolved_counts, &catalog_count_text/1) == ["35", "Unresolved", "Unresolved"]
    assert Enum.map(empty_counts, &catalog_count_text/1) == ["0", "0", "0"]

    assert unresolved_counts
           |> Enum.drop(1)
           |> Enum.all?(
             &(Floki.find(
                 &1,
                 ~s(.bo-catalog-progress-unresolved.bo-catalog-count-unresolved[data-count-state="unresolved"])
               ) != [])
           )

    unresolved_markers =
      unresolved_counts
      |> Enum.drop(1)
      |> Enum.flat_map(&Floki.find(&1, ".bo-catalog-count-unresolved"))

    assert Enum.map(unresolved_markers, &Floki.attribute(&1, "role")) == [["img"], ["img"]]

    assert Enum.map(unresolved_markers, &Floki.attribute(&1, "aria-label")) == [
             ["Epics unresolved; count not fetched"],
             ["Waves unresolved; count not fetched"]
           ]

    assert Enum.map(unresolved_markers, &Floki.attribute(&1, "title")) == [
             ["Epics were not fetched for this catalog entry"],
             ["Waves were not fetched for this catalog entry"]
           ]

    refute Floki.find(unresolved_counts, ".bo-catalog-invalid") != []
    assert Enum.all?(empty_counts, &(Floki.find(&1, "[data-count-state]") == []))
    refute Floki.raw_html(unresolved_counts) =~ "—"
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
    assert cold_html =~ "Loading Build Order catalog"
    GenServer.stop(cold_view.pid)
    assert Process.alive?(cold)

    unavailable = install_source(catalog: catalog_snapshot(nil, :unknown, :unavailable))
    assert {:ok, unavailable_view, unavailable_html} = live(build_conn(), "/build-orders")
    assert unavailable_html =~ ~s(data-build-order-catalog-state="unavailable")
    assert unavailable_html =~ "Catalog unavailable"
    GenServer.stop(unavailable_view.pid)
    assert Process.alive?(unavailable)

    identity = identity(42, "NODE-42")
    stale = install_source(catalog: catalog_snapshot([root(identity, "Stale root")], 1, :stale))
    assert {:ok, _view, stale_html} = live(build_conn(), "/build-orders")
    assert stale_html =~ ~s(data-build-order-catalog-state="stale_lkg")
    assert stale_html =~ "Showing the last-known-good catalog"
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

    assert html =~ ~s(data-build-order-root="42")
    assert html =~ "Root forty-two"
    assert html =~ "Valid empty graph"
    refute html =~ ~s(data-layout-node)

    calls = FakeDataSource.calls(source)
    subscribe_index = call_index(calls, {:subscribe_selected, [first]})
    demand_index = call_index(calls, {:demand, [first]})

    assert subscribe_index < demand_index
    assert Enum.count(calls, &(&1 == {:demand, [first]})) == 1
    refute Enum.any?(calls, &match?({:selected, _}, &1))
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

    assert html =~ ~s(data-build-order-status="invalid_parameter")
    assert html =~ "Invalid Build Order URL"
    refute Enum.any?(FakeDataSource.calls(source), &match?({:demand, _}, &1))
  end

  test "marks a selected root unavailable when its initial demand fails", %{first: first} do
    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: []
      )

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ ~s(data-build-order-status="selected_unavailable")
    assert html =~ "Selected graph unavailable"
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
    render_async(view, 2_000)
    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="working"]), "agent live")
    assert has_element?(view, ~s([data-bo-card="7"]), "30%")

    Agent.update(sources, fn _sources ->
      sources_for_member(member.identity, :paused, :operator_pause, 45)
    end)

    :ok = AgentPubSub.broadcast_running_change([])

    render_async(view, 2_000)
    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="plain"]), "Paused")
    assert has_element?(view, ~s([data-bo-card="7"]), "45%")

    Agent.update(sources, fn _sources -> sources_for_ci_wait_member(member.identity, 60) end)
    :ok = AgentPubSub.broadcast_running_change([])

    render_async(view, 2_000)
    assert has_element?(view, ~s([data-bo-card="7"][data-bo-state="plain"]), "CI waiting")
    assert has_element?(view, ~s([data-bo-card="7"]), "60%")
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
    assert html =~ "Root forty-two"

    new_catalog =
      catalog_snapshot([root(first, "New-instance root")], 1, :healthy, repository(), 2)

    new_selected =
      selected_snapshot(first, "New-instance generation one", 1, :healthy, authority_epoch: 2)

    :ok = FakeDataSource.put_catalog(source, new_catalog)
    :ok = FakeDataSource.put_selected(source, new_selected)

    send(view.pid, {:graph_projection_reset, 2})
    assert render(view) =~ "New-instance generation one"

    old_catalog =
      catalog_snapshot([root(first, "Queued old catalog")], 99, :healthy, repository(), 1)

    old_selected =
      selected_snapshot(first, "Queued old selected root", 99, :healthy, authority_epoch: 1)

    send(view.pid, {:graph_projection_generation, old_catalog})
    send(view.pid, {:graph_projection_generation, old_selected})

    final_html = render(view)
    assert final_html =~ "New-instance generation one"
    refute final_html =~ "Queued old catalog"
    refute final_html =~ "Queued old selected root"
  end

  test "coalesces source invalidation bursts behind one in-flight cached read" do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    loader = fn ->
      call = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      send(parent, {:source_load_started, call, self()})

      receive do
        {:release_sources, ^call} ->
          %{
            execution: %{running: [], retrying: [], idle: []},
            activity: %{generation: call, entries: []}
          }
      end
    end

    _source = install_source(catalog: catalog_snapshot([], 1, :healthy), sources_loader: loader)
    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    assert_receive {:source_load_started, 1, first_loader}, 2_000

    send(view.pid, {:ticket_activity_changed, %{generation: 2}})
    send(view.pid, {:running_changed, []})
    send(first_loader, {:release_sources, 1})
    assert_receive {:source_load_started, 2, second_loader}, 2_000
    refute_receive {:source_load_started, 3, _loader}, 100

    send(second_loader, {:release_sources, 2})
    render_async(view, 2_000)
    refute_receive {:source_load_started, 3, _loader}, 100
  end

  test "patching between roots releases the old scope before activating the new one", %{
    source: source,
    first: first,
    second: second
  } do
    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    html = render_patch(view, "/build-orders/43")

    assert html =~ ~s(data-build-order-root="43")
    assert html =~ "Root forty-three"

    calls = FakeDataSource.calls(source)
    release_index = call_index(calls, {:release, [first]})
    unsubscribe_index = call_index(calls, {:unsubscribe_selected, [first]})
    subscribe_index = call_index(calls, {:subscribe_selected, [second]})
    demand_index = call_index(calls, {:demand, [second]})

    assert release_index < unsubscribe_index
    assert unsubscribe_index < subscribe_index
    assert subscribe_index < demand_index
  end

  test "selected publications reject the wrong root and accept one newer generation", %{
    first: first,
    second: second
  } do
    {:ok, view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ "Root forty-two"

    send(
      view.pid,
      {:graph_projection_generation, selected_snapshot(second, "Wrong delayed root", 99, :healthy)}
    )

    refute render(view) =~ "Wrong delayed root"

    send(
      view.pid,
      {:graph_projection_generation, selected_snapshot(first, "Root forty-two updated", 2, :healthy)}
    )

    assert render(view) =~ "Root forty-two updated"

    send(
      view.pid,
      {:graph_projection_health, selected_snapshot(first, nil, 2, :stale, refreshing?: true)}
    )

    health_html = render(view)
    assert health_html =~ ~s(data-build-order-status="selected_stale")
    assert health_html =~ "Root forty-two updated"
    # Degraded provider states surface as an explicit state card (the always-on
    # health badge was removed from the header).
    assert health_html =~ "Stale last-known-good graph"
  end

  test "keeps structurally invalid selected data visible as an explicit diagnostic state", %{
    first: first
  } do
    {:ok, view, _html} = live(build_conn(), "/build-orders/42")

    invalid = SelectedRoot.new(RootSummary.new(%{}), [], health(2, :healthy))
    send(view.pid, {:graph_projection_generation, selected_snapshot(first, invalid, 2, :healthy)})

    html = render(view)
    assert html =~ ~s(data-build-order-status="selected_invalid")
    assert html =~ "Structurally invalid graph"
    assert html =~ "Root data is unavailable."
  end

  test "rejects a delayed context completion after close", %{first: first} do
    parent = self()

    loader = fn identity ->
      send(parent, {:context_load_started, self(), identity})

      receive do
        :release_context -> %{detail: {:error, :unavailable}, history: {:error, :unavailable}}
      end
    end

    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()

    assert_receive {:context_load_started, loader_pid, selected_identity}, 2_000
    assert selected_identity.identifier == "7"
    assert has_element?(view, ~s([role="dialog"]))

    view |> element(~s(button[phx-click="build-order-context-close"])) |> render_click()
    refute has_element?(view, ~s([role="dialog"]))

    send(loader_pid, :release_context)
    render_async(view, 2_000)
    refute has_element?(view, ~s([role="dialog"]))

    calls = FakeDataSource.calls(source)
    assert {:subscribe_context, [selected_identity]} in calls
    assert {:load_context, [selected_identity]} in calls
    assert {:unsubscribe_context, [selected_identity]} in calls
  end

  test "root switch closes old context scope and rejects its delayed completion", %{
    first: first,
    second: second
  } do
    parent = self()

    loader = fn identity ->
      send(parent, {:context_load_started, self(), identity})

      receive do
        :release_context -> context_result(identity, "Delayed old-root context")
      end
    end

    first_snapshot = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    second_snapshot =
      selected_snapshot(second, "Root forty-three", 1, :healthy, members: [member(8)])

    source =
      install_source(
        catalog:
          catalog_snapshot(
            [root(first, "Root forty-two"), root(second, "Root forty-three")],
            1,
            :healthy
          ),
        selected: [first_snapshot, second_snapshot],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()
    assert_receive {:context_load_started, loader_pid, old_context_identity}, 2_000

    html = render_patch(view, "/build-orders/43")
    assert html =~ ~s(data-build-order-root="43")
    refute has_element?(view, ~s([role="dialog"]))
    assert {:unsubscribe_context, [old_context_identity]} in FakeDataSource.calls(source)

    send(loader_pid, :release_context)
    render_async(view, 2_000)
    refute render(view) =~ "Delayed old-root context"
    refute has_element?(view, ~s([role="dialog"]))
  end

  test "rotates context identity and coalesces an invalidation behind an in-flight read", %{
    first: first
  } do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    loader = fn identity ->
      call = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      send(parent, {:context_load_started, call, self(), identity})

      receive do
        {:release_context, ^call} -> context_result(identity, "Context version #{call}")
      end
    end

    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()

    assert_receive {:context_load_started, 1, first_loader, selected_identity}, 2_000
    send(view.pid, {:ticket_detail_updated, %{identity: selected_identity}})
    send(first_loader, {:release_context, 1})

    assert_receive {:context_load_started, 2, second_loader, ^selected_identity}, 2_000
    refute render(view) =~ "Context version 1"
    send(second_loader, {:release_context, 2})
    render_async(view, 2_000)
    assert render(view) =~ "Context version 2"

    assert Enum.count(
             FakeDataSource.calls(source),
             &match?({:load_context, [^selected_identity]}, &1)
           ) == 2
  end

  test "ignores cache publications for a different open identity", %{first: first} do
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected]
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()
    render_async(view, 2_000)
    calls_before = FakeDataSource.calls(source)

    send(view.pid, {:ticket_detail_updated, %{identity: identity(99, "NODE-99")}})
    _ = render(view)
    assert FakeDataSource.calls(source) == calls_before
  end

  test "releases the selected demand and context subscriptions on termination", %{first: first} do
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected]
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s([phx-click="open-ticket-context"])) |> render_click()
    render_async(view, 2_000)
    selected_identity = identity(7, "NODE-7")
    GenServer.stop(view.pid)

    calls = FakeDataSource.calls(source)
    assert {:release, [first]} in calls
    assert {:unsubscribe_selected, [first]} in calls
    assert {:unsubscribe_context, [selected_identity]} in calls
  end

  defp call_index(calls, expected) do
    Enum.find_index(calls, &(&1 == expected)) ||
      flunk("missing source call #{inspect(expected)} in #{inspect(calls)}")
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

  defp catalog_snapshot(
         entries,
         generation,
         state,
         snapshot_repository \\ repository(),
         authority_epoch \\ 1
       ) do
    data = if is_list(entries), do: Catalog.new(entries, health(generation, state))

    %Snapshot{
      scope: :catalog,
      repository: snapshot_repository,
      authority_epoch: authority_epoch,
      generation: generation,
      data: data,
      health: health(generation, state)
    }
  end

  defp selected_snapshot(identity, title_or_data, generation, state, opts \\ [])

  defp selected_snapshot(identity, %SelectedRoot{} = data, generation, state, opts) do
    %Snapshot{
      scope: {:selected, identity},
      repository: Keyword.get(opts, :repository, repository()),
      authority_epoch: Keyword.get(opts, :authority_epoch, 1),
      generation: generation,
      data: data,
      health: health(generation, state, opts)
    }
  end

  defp selected_snapshot(identity, title, generation, state, opts) do
    data =
      if is_binary(title),
        do:
          SelectedRoot.new(
            root(identity, title),
            Keyword.get(opts, :members, []),
            health(generation, state)
          ),
        else: nil

    %Snapshot{
      scope: {:selected, identity},
      repository: Keyword.get(opts, :repository, repository()),
      authority_epoch: Keyword.get(opts, :authority_epoch, 1),
      generation: generation,
      data: data,
      health: health(generation, state, opts)
    }
  end

  defp root(identity, title) do
    RootSummary.new(%{
      identity: identity,
      title: title,
      url: "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp member(number) do
    identity = identity(number, "NODE-#{number}")

    Member.new(%{
      identity: identity,
      title: "Ticket #{number}",
      url: "https://github.com/owner/repo/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: ["phase:1", "build-lane:dashboard-ui"]
    })
  end

  defp breakdown_member(number, opts) do
    identity = identity(number, "NODE-#{number}")

    labels = [
      "complexity:#{Keyword.fetch!(opts, :complexity)}",
      "phase:#{Keyword.fetch!(opts, :phase)}",
      "build-lane:#{Keyword.fetch!(opts, :lane)}"
    ]

    Member.new(%{
      identity: identity,
      title: "Ticket #{number}",
      url: "https://github.com/owner/repo/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: labels
    })
  end

  defp sources_with_adhoc(adhoc) do
    %{
      execution: %{running: [], retrying: [], idle: []},
      activity: %{generation: 1, entries: []},
      adhoc: adhoc
    }
  end

  defp sources_for_member(identity, work_state, pause_reason, progress) do
    observed_at = ~U[2026-08-01 12:00:00Z]

    %{
      execution: %{
        running: [
          %{
            tracker_identity: identity,
            work_state: work_state,
            pause_reason: pause_reason,
            tracker_paused: work_state == :paused,
            waiting_reason: :active,
            started_at: observed_at
          }
        ],
        retrying: [],
        idle: []
      },
      activity: %{
        generation: progress,
        entries: [
          %{
            identity: identity,
            status: :fresh,
            active_stage: :work,
            stage: %{
              status: :known,
              value: :work,
              freshness: :fresh,
              observed_at: observed_at,
              event_id: progress
            },
            progress: %{
              status: :known,
              percent: progress,
              source: :checkin,
              freshness: :fresh,
              occurred_at: observed_at,
              observed_at: observed_at,
              event_id: progress
            },
            observed_at: observed_at,
            retention: :current
          }
        ]
      },
      adhoc: nil
    }
  end

  defp sources_for_ci_wait_member(identity, progress) do
    sources_for_member(identity, :idle, nil, progress)
    |> put_in([:execution, :running], [])
    |> put_in([:execution, :idle], [
      %{tracker_identity: identity, waiting_reason: :waiting_for_ci}
    ])
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

  defp health(generation, state, opts \\ []) do
    ProviderHealth.new(generation, state, state == :healthy, opts)
  end

  defp identity(number, provider_id, identity_repository \\ repository()) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        identity_repository,
        identity_repository
      )

    identity
  end

  defp repository, do: {"owner", "repo"}

  defp context_result(identity, title) do
    observed_at = ~U[2026-07-17 12:00:00Z]

    detail = %State{
      identity: identity,
      generation: 1,
      health: :healthy,
      detail: %DetailSnapshot{
        identity: identity,
        title: title,
        description: "Cached context",
        lifecycle: Lifecycle.from_github("OPEN", nil),
        url: "https://github.com/owner/repo/issues/#{identity.identifier}",
        created_at: observed_at,
        updated_at: observed_at,
        observed_at: observed_at
      },
      last_success_at: observed_at,
      last_attempt_at: observed_at
    }

    history = %TicketHistory.Snapshot{
      identity: identity,
      generation: 1,
      health: :available,
      status_label: "Current activity",
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      entries: [],
      truncated?: false,
      observed_at: observed_at,
      freshness: :fresh,
      source_health: %{activity: :available, history: :available}
    }

    %{detail: {:ok, detail}, history: {:ok, history}}
  end

  defp install_source(opts) do
    source =
      start_supervised!(
        Supervisor.child_spec(
          {FakeDataSource,
           [
             report: self(),
             catalog: Keyword.get(opts, :catalog),
             selected: Keyword.get(opts, :selected, []),
             sources_loader:
               Keyword.get(opts, :sources_loader, fn ->
                 %{
                   execution: %{running: [], retrying: [], idle: []},
                   activity: %{generation: 1, entries: []}
                 }
               end),
             context_loader:
               Keyword.get(opts, :context_loader, fn _identity ->
                 %{detail: {:error, :unavailable}, history: {:error, :unavailable}}
               end)
           ]},
          id: make_ref()
        )
      )

    Application.put_env(:aiur, :build_order_data_source, {FakeDataSource, source})
    source
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

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

    assert html =~ "Build Order analytics"

    # The two surfaces must be unmistakable: this one is build-scoped, /analytics is session-scoped.
    assert html =~ "this Build Order"
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
    html = render_async(view)

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
    html = render_async(view)

    assert html =~ "Sessions"
    assert html =~ "CPU burned"
    assert html =~ "Member lifecycle"
    assert html =~ "Current session, scoped to members of this Build Order."
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
    html = render_async(view)
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
    html = render_async(view)

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

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Build Order" do
    {:ok, _view, html} = live(build_conn(), "/build-orders")

    assert html =~ "2 units awaiting commands"
    assert html =~ ~s(href="/decisions")
  end

  @tag awaiting_commands: %{total: 4, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
  test "omits the awaiting-Commands banner from Build Order when nothing is waiting" do
    {:ok, _view, html} = live(build_conn(), "/build-orders")

    refute html =~ "units awaiting commands"
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "survives every message the Command topic carries" do
    {:ok, view, html} = live(build_conn(), "/build-orders")
    assert html =~ "2 units awaiting commands"

    assert AwaitingCommands.render_after_command_topic(view) =~ "2 units awaiting commands"
  end

  # --- awaiting-Commands banner ---------------------------------------------

  defp awaiting_commands_config(context) do
    case context[:awaiting_commands] do
      nil -> []
      counts -> [decision_store: AwaitingCommands.start(counts)]
    end
  end
end
