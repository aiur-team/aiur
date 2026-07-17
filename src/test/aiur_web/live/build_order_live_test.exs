defmodule AiurWeb.BuildOrderLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.TicketDetail.State
  alias Aiur.BuildOrder.TicketDetail.Snapshot, as: DetailSnapshot
  alias Aiur.BuildOrder.TicketHistory
  alias Aiur.TrackerIdentity
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  defmodule FakeDataSource do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def calls(server), do: GenServer.call(server, :calls)
    def put_catalog(server, catalog), do: GenServer.call(server, {:put_catalog, catalog})

    def subscribe_catalog(server), do: invoke(server, :subscribe_catalog, [])
    def unsubscribe_catalog(server, repository), do: invoke(server, :unsubscribe_catalog, [repository])
    def catalog(server), do: invoke(server, :catalog, [])
    def subscribe_sources(server), do: invoke(server, :subscribe_sources, [])

    def load_sources(server) do
      loader = invoke(server, :load_sources, [])
      loader.()
    end

    def subscribe_selected(server, identity), do: invoke(server, :subscribe_selected, [identity])
    def unsubscribe_selected(server, identity), do: invoke(server, :unsubscribe_selected, [identity])
    def selected(server, identity), do: invoke(server, :selected, [identity])
    def demand(server, identity), do: invoke(server, :demand, [identity])
    def release(server, identity), do: invoke(server, :release, [identity])
    def subscribe_context(server, identity), do: invoke(server, :subscribe_context, [identity])
    def unsubscribe_context(server, identity), do: invoke(server, :unsubscribe_context, [identity])

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
         sources: Keyword.get(opts, :sources, %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: 1, entries: []}}),
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
    def handle_call({:put_catalog, catalog}, _from, state), do: {:reply, :ok, %{state | catalog: catalog}}

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

  setup do
    first = identity(42, "NODE-42")
    second = identity(43, "NODE-43")
    catalog = catalog_snapshot([root(first, "Root forty-two"), root(second, "Root forty-three")], 1, :healthy)

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

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      restore_application_env(:build_order_data_source, previous_source)
      restore_application_env(Endpoint, previous_endpoint)
    end)

    %{source: source, first: first, second: second}
  end

  test "mounts the catalog without demanding any selected root", %{source: source} do
    assert {:ok, _view, html} = live(build_conn(), "/build-orders")

    assert html =~ ~s(<h1 id="route-title">Build Order</h1>)
    assert html =~ ~s(data-build-order-status="catalog")
    assert html =~ "Build Order catalog"

    calls = FakeDataSource.calls(source)
    assert {:subscribe_catalog, []} in calls
    assert {:catalog, []} in calls
    assert {:subscribe_sources, []} in calls
    refute Enum.any?(calls, &match?({:demand, _}, &1))
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
    assert empty_html =~ "No Build Orders"
    assert Process.alive?(empty)
  end

  test "deep links resolve through the catalog and subscribe before one demand", %{source: source, first: first} do
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
    source = install_source(catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy))

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
    source = install_source(catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy), selected: [])

    assert {:ok, _view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ ~s(data-build-order-status="selected_unavailable")
    assert html =~ "Selected graph unavailable"
    assert {:demand, [first]} in FakeDataSource.calls(source)
  end

  test "projection reset rolls the catalog subscription to the replacement repository", %{source: source} do
    assert {:ok, view, _html} = live(build_conn(), "/build-orders")
    replacement_repository = {"new-owner", "new-repo"}
    replacement = identity(52, "NEW-52", replacement_repository)

    :ok =
      FakeDataSource.put_catalog(
        source,
        catalog_snapshot([root(replacement, "Replacement root")], 1, :healthy, replacement_repository)
      )

    send(view.pid, {:graph_projection_reset, 2})
    assert render(view) =~ "Replacement root"

    calls = FakeDataSource.calls(source)
    unsubscribe_index = call_index(calls, {:unsubscribe_catalog, [repository()]})
    resubscribe_index = call_index_after(calls, {:subscribe_catalog, []}, unsubscribe_index)
    reload_index = call_index_after(calls, {:catalog, []}, resubscribe_index)
    assert unsubscribe_index < resubscribe_index
    assert resubscribe_index < reload_index

    publication = catalog_snapshot([root(replacement, "Replacement root updated")], 2, :healthy, replacement_repository)
    send(view.pid, {:graph_projection_generation, publication})
    assert render(view) =~ "Replacement root updated"

    :ok =
      FakeDataSource.put_catalog(
        source,
        catalog_snapshot([root(replacement, "Restarted projection root")], 1, :healthy, replacement_repository)
      )

    send(view.pid, {:graph_projection_reset, 1})
    assert render(view) =~ "Restarted projection root"
  end

  test "coalesces source invalidation bursts behind one in-flight cached read" do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    loader = fn ->
      call = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      send(parent, {:source_load_started, call, self()})

      receive do
        {:release_sources, ^call} ->
          %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: call, entries: []}}
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

  test "selected publications reject the wrong root and accept one newer generation", %{first: first, second: second} do
    {:ok, view, html} = live(build_conn(), "/build-orders/42")
    assert html =~ "Root forty-two"

    send(view.pid, {:graph_projection_generation, selected_snapshot(second, "Wrong delayed root", 99, :healthy)})
    refute render(view) =~ "Wrong delayed root"

    send(view.pid, {:graph_projection_generation, selected_snapshot(first, "Root forty-two updated", 2, :healthy)})
    assert render(view) =~ "Root forty-two updated"

    send(view.pid, {:graph_projection_health, selected_snapshot(first, nil, 2, :stale, refreshing?: true)})
    health_html = render(view)
    assert health_html =~ ~s(data-build-order-status="selected_stale")
    assert health_html =~ "Root forty-two updated"
    assert health_html =~ "Stale last-known-good graph"
    assert health_html =~ "Stale"
    assert health_html =~ "Refreshing"
  end

  test "keeps structurally invalid selected data visible as an explicit diagnostic state", %{first: first} do
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
    source = install_source(catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy), selected: [selected], context_loader: loader)

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s(button[phx-click="open-ticket-context"])) |> render_click()

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
    second_snapshot = selected_snapshot(second, "Root forty-three", 1, :healthy, members: [member(8)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two"), root(second, "Root forty-three")], 1, :healthy),
        selected: [first_snapshot, second_snapshot],
        context_loader: loader
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s(button[phx-click="open-ticket-context"])) |> render_click()
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

  test "rotates context identity and coalesces an invalidation behind an in-flight read", %{first: first} do
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
    view |> element(~s(button[phx-click="open-ticket-context"])) |> render_click()

    assert_receive {:context_load_started, 1, first_loader, selected_identity}, 2_000
    send(view.pid, {:ticket_detail_updated, %{identity: selected_identity}})
    send(first_loader, {:release_context, 1})

    assert_receive {:context_load_started, 2, second_loader, ^selected_identity}, 2_000
    refute render(view) =~ "Context version 1"
    send(second_loader, {:release_context, 2})
    render_async(view, 2_000)
    assert render(view) =~ "Context version 2"
    assert Enum.count(FakeDataSource.calls(source), &match?({:load_context, [^selected_identity]}, &1)) == 2
  end

  test "ignores cache publications for a different open identity", %{first: first} do
    selected = selected_snapshot(first, "Root forty-two", 1, :healthy, members: [member(7)])

    source =
      install_source(
        catalog: catalog_snapshot([root(first, "Root forty-two")], 1, :healthy),
        selected: [selected]
      )

    {:ok, view, _html} = live(build_conn(), "/build-orders/42")
    view |> element(~s(button[phx-click="open-ticket-context"])) |> render_click()
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
    view |> element(~s(button[phx-click="open-ticket-context"])) |> render_click()
    render_async(view, 2_000)
    selected_identity = identity(7, "NODE-7")
    GenServer.stop(view.pid)

    calls = FakeDataSource.calls(source)
    assert {:release, [first]} in calls
    assert {:unsubscribe_selected, [first]} in calls
    assert {:unsubscribe_context, [selected_identity]} in calls
  end

  defp call_index(calls, expected) do
    Enum.find_index(calls, &(&1 == expected)) || flunk("missing source call #{inspect(expected)} in #{inspect(calls)}")
  end

  defp call_index_after(calls, expected, index) do
    calls
    |> Enum.with_index()
    |> Enum.find_value(fn {call, call_index} -> if call == expected and call_index > index, do: call_index end)
    |> case do
      nil -> flunk("missing source call #{inspect(expected)} after #{index} in #{inspect(calls)}")
      call_index -> call_index
    end
  end

  defp catalog_snapshot(entries, generation, state, snapshot_repository \\ repository()) do
    data = if is_list(entries), do: Catalog.new(entries, health(generation, state))

    %Snapshot{
      scope: :catalog,
      repository: snapshot_repository,
      generation: generation,
      data: data,
      health: health(generation, state)
    }
  end

  defp selected_snapshot(identity, title_or_data, generation, state, opts \\ [])

  defp selected_snapshot(identity, %SelectedRoot{} = data, generation, state, opts) do
    %Snapshot{
      scope: {:selected, identity},
      repository: repository(),
      generation: generation,
      data: data,
      health: health(generation, state, opts)
    }
  end

  defp selected_snapshot(identity, title, generation, state, opts) do
    data =
      if is_binary(title),
        do: SelectedRoot.new(root(identity, title), Keyword.get(opts, :members, []), health(generation, state)),
        else: nil

    %Snapshot{
      scope: {:selected, identity},
      repository: repository(),
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
        lifecycle: Aiur.BuildOrder.Lifecycle.from_github("OPEN", nil),
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
                 %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: 1, entries: []}}
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
end
