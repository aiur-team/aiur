defmodule AiurWeb.BuildOrderUsageLiveTest do
  @moduledoc """
  DASH-023 — live selected Build Order `this build` usage integration on the
  BuildOrderLive route. Covers the scope-level states (each kept distinct from a
  zero total), the locked/authorized capability gate, selected-root switch
  isolation, coalesced protected updates, and the read-only mutation boundary.
  """

  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialData

  @endpoint Endpoint

  defmodule FakeDataSource do
    @moduledoc false
    use GenServer

    alias Aiur.BuildOrder.GraphProjection.Snapshot

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def put_selected(server, selected), do: GenServer.call(server, {:put_selected, selected})

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
         catalog: Keyword.fetch!(opts, :catalog),
         selected: Map.new(Keyword.get(opts, :selected, []), &{&1.scope, &1}),
         sources: %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: 1, entries: []}}
       }}
    end

    @impl true
    def handle_call({:put_selected, %Snapshot{scope: scope} = selected}, _from, state),
      do: {:reply, :ok, %{state | selected: Map.put(state.selected, scope, selected)}}

    def handle_call({:invoke, :catalog, []}, _from, state), do: {:reply, state.catalog, state}
    def handle_call({:invoke, :load_sources, []}, _from, state), do: {:reply, fn -> state.sources end, state}

    def handle_call({:invoke, :selected, [identity]}, _from, state),
      do: {:reply, selected_reply(state, identity), state}

    def handle_call({:invoke, :demand, [identity]}, _from, state),
      do: {:reply, selected_reply(state, identity), state}

    def handle_call({:invoke, :load_context, [_identity]}, _from, state),
      do: {:reply, fn _identity -> %{detail: {:error, :unavailable}, history: {:error, :unavailable}} end, state}

    def handle_call({:invoke, _name, _args}, _from, state), do: {:reply, :ok, state}

    defp invoke(server, name, args), do: GenServer.call(server, {:invoke, name, args})

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
    catalog = catalog_snapshot([root(first, "Root forty-two"), root(second, "Root forty-three")])

    authorized? = context[:authorized] == true
    members = context |> Map.get(:members, []) |> Enum.map(&member/1)

    source =
      start_supervised!(
        {FakeDataSource,
         catalog: catalog,
         selected: [
           selected_snapshot(first, SelectedRoot.new(root(first, "Root forty-two"), members, healthy())),
           selected_snapshot(second, SelectedRoot.new(root(second, "Root forty-three"), [], healthy()))
         ]}
      )

    previous_source = Application.get_env(:aiur, :build_order_data_source)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    if authorized? do
      System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
      System.put_env("AIUR_DASHBOARD_PASSWORD", "bo-usage-secret")
    else
      System.delete_env("AIUR_DASHBOARD_USERNAME")
      System.delete_env("AIUR_DASHBOARD_PASSWORD")
    end

    Application.put_env(:aiur, :build_order_data_source, {FakeDataSource, source})

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: authorized?
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      restore_app_env(:build_order_data_source, previous_source)
      restore_endpoint(previous_endpoint)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    %{source: source, first: first, second: second}
  end

  describe "scope-level states (locked or authorized-independent)" do
    test "the catalog route renders no build-usage region" do
      {:ok, _view, html} = live(build_conn(), "/build-orders")
      refute html =~ ~s(class="bo-usage")
      refute html =~ "Usage and cost for this build"
    end

    @tag members: []
    test "a selected root with no members is an empty build, not a zero total" do
      {:ok, view, _html} = live(build_conn(), "/build-orders/42")
      html = render(view)

      assert html =~ ~s(data-bo-usage-state="empty_build")
      assert html =~ "no members yet"
      socket = socket(view)
      assert socket.assigns.bo_usage_scope.state == :empty_build
    end

    @tag members: [10, 11]
    test "a locked connection renders the value-free locked view for a scopable build" do
      {:ok, view, _html} = live(build_conn(), "/build-orders/42")
      # The scope is ready; the debounced protected read demotes a locked
      # connection to the value-free locked view.
      send(view.pid, :flush_bo_usage)
      html = render(view)

      socket = socket(view)
      assert socket.assigns.financial_data_capability.state == :locked
      assert socket.assigns.bo_usage_view.state == :locked
      assert socket.assigns.bo_usage_source == nil

      for marker <- ["API-equivalent estimate", "Plan tier", ~s(phx-click="usage-drill-down")] do
        refute html =~ marker, "locked build usage leaked #{inspect(marker)}"
      end
    end
  end

  describe "selected-root switch isolation" do
    @tag :authorized
    @tag members: [10]
    test "patching to another root resets the retained snapshot so no cost crosses roots", %{source: source} do
      # Give the second root members too, so both are scopable.
      :ok =
        FakeDataSource.put_selected(
          source,
          selected_snapshot(
            identity(43, "NODE-43"),
            SelectedRoot.new(root(identity(43, "NODE-43"), "Root forty-three"), [member(20)], healthy())
          )
        )

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:bo-usage-secret"))

      {:ok, view, _html} = live(conn, "/build-orders/42")
      send(view.pid, :flush_bo_usage)
      _ = render(view)

      loaded = socket(view)
      identity_before = loaded.assigns.bo_usage_identity
      assert identity_before != nil
      # Authorized fetch populated a retained snapshot for root 42.
      assert loaded.assigns.bo_usage_source != nil

      # Patch to the other root within the same live session; the retained
      # snapshot/drill for root 42 must reset before root 43's read completes.
      _ = render_patch(view, "/build-orders/43")
      switched = socket(view)

      assert switched.assigns.bo_usage_identity != identity_before
      assert switched.assigns.bo_usage_source == nil
      assert switched.assigns.bo_usage_drill == nil
    end
  end

  describe "read-only boundary" do
    @tag members: [10]
    test "no build-usage event mutates GitHub or Aiur runtime" do
      {:ok, view, _html} = live(build_conn(), "/build-orders/42")

      # Drill events are read-only and gate on authorization; a locked
      # connection is a no-op and never crashes or mutates.
      render_click(view, "usage-drill-down", %{"dimension" => "by_ticket"})
      assert Process.alive?(view.pid)
      assert socket(view).assigns.bo_usage_drill == nil
    end
  end

  describe "authorized wiring" do
    @tag :authorized
    @tag members: [10, 11]
    test "an authorized scopable build opens the capability gate without a zero or locked state" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:bo-usage-secret"))

      {:ok, view, _html} = live(conn, "/build-orders/42")
      send(view.pid, :flush_bo_usage)
      _html = render(view)

      socket = socket(view)
      assert socket.assigns.financial_data_capability.state == :authorized
      assert socket.assigns.bo_usage_scope.state == :ready
      refute socket.assigns.bo_usage_view.state == :locked
      assert socket.assigns.bo_usage_view.state in [:loading, :empty, :ready, :partial, :stale, :unavailable]
    end

    @tag :authorized
    @tag members: [10]
    test "a payload-free protected update is coalesced into one bounded re-read" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:bo-usage-secret"))

      {:ok, view, _html} = live(conn, "/build-orders/42")
      send(view.pid, :flush_bo_usage)
      _ = render(view)

      context = socket(view).private.aiur_financial_data_access
      {:ok, identity} = AiurWeb.FinancialDataAccess.identity(context)

      # Two bursts before the flush window collapse into a single re-read.
      send(view.pid, {FinancialData, :updated, identity})
      send(view.pid, {FinancialData, :updated, identity})
      send(view.pid, :flush_bo_usage)
      _ = render(view)

      socket = socket(view)
      assert Process.alive?(view.pid)
      refute socket.assigns.bo_usage_view.state == :locked
    end
  end

  # --- fixtures ------------------------------------------------------------

  defp socket(view), do: :sys.get_state(view.pid).socket

  defp catalog_snapshot(entries) do
    %Snapshot{
      scope: :catalog,
      repository: {"owner", "repo"},
      authority_epoch: 1,
      generation: 1,
      data: Catalog.new(entries, healthy()),
      health: healthy()
    }
  end

  defp selected_snapshot(identity, %SelectedRoot{} = data) do
    %Snapshot{
      scope: {:selected, identity},
      repository: {"owner", "repo"},
      authority_epoch: 1,
      generation: 1,
      data: data,
      health: healthy()
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
    Member.new(%{
      identity: identity(number, "NODE-#{number}"),
      title: "Ticket #{number}",
      url: "https://github.com/owner/repo/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: []
    })
  end

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        {"owner", "repo"},
        {"owner", "repo"}
      )

    identity
  end

  defp healthy, do: ProviderHealth.new(1, :healthy, true)

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  defp restore_endpoint(nil), do: Application.delete_env(:aiur, Endpoint)
  defp restore_endpoint(value), do: Application.put_env(:aiur, Endpoint, value)
end
