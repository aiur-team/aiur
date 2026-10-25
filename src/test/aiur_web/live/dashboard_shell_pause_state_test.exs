defmodule AiurWeb.DashboardShellPauseStateTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.Orchestrator.{GlobalPause, SnapshotCache, SnapshotStore}
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.{DashboardShell, PauseState, RouteRegistry}

  @endpoint Endpoint

  defmodule StartingOrchestrator do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :starting)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(_request, _from, state), do: {:reply, :starting, state}
  end

  setup do
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_store = Application.get_env(:aiur, :global_pause_store_path)
    store = Path.join(Aiur.TestSupport.tmp_root!("dashboard-shell-pause"), "global-pause.json")

    Application.put_env(:aiur, :global_pause_store_path, store)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(previous_endpoint || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: false,
        dashboard_writable: true
      )
    )

    Aiur.TestSupport.start_owned_endpoint!()
    assert {:ok, _} = GlobalPause.set_global_pause(false)

    on_exit(fn ->
      assert {:ok, _} = GlobalPause.set_global_pause(false)
      restore(:global_pause_store_path, previous_store)
      restore(Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "every shell page renders the orchestrator's current global pause state" do
    for {paused, label} <- [{false, "Pause new starts"}, {true, "Resume new starts"}] do
      for path <- ["/analytics", "/", "/build", "/units", "/streamdeck", "/post-deploy"] do
        assert {:ok, _} = GlobalPause.set_global_pause(paused)
        {:ok, view, html} = live(authorized_conn(), path)

        assert html =~ label, path
        if path == "/post-deploy", do: assert(html =~ "Post-deploy checks")
        refute html =~ "Pause state unknown", path
        assert has_element?(view, "#ax-pause[aria-checked=#{paused}]"), path
        refute has_element?(view, "#ax-pause[disabled]"), path

        target = not paused
        expected_after_click = if target, do: "Resume new starts", else: "Pause new starts"
        assert view |> element("#ax-pause") |> render_click() =~ expected_after_click, path
        assert {:ok, %{globally_paused: ^target}} = GlobalPause.global_pause_status()

        {:ok, _reloaded_view, reloaded_html} = live(authorized_conn(), path)
        assert reloaded_html =~ expected_after_click, path
      end
    end
  end

  test "updates the shell when global pause changes elsewhere" do
    assert {:ok, _} = GlobalPause.set_global_pause(false)
    {:ok, view, _html} = live(authorized_conn(), "/analytics")

    assert {:ok, _} = GlobalPause.set_global_pause(true)

    Process.sleep(600)
    assert render(view) =~ "Resume new starts"
    assert has_element?(view, "#ax-pause[aria-checked=true]")
  end

  test "coalesces a pause invalidation burst into one snapshot read" do
    {:ok, view, _html} = live(authorized_conn(), "/analytics")
    :erlang.trace_pattern({SnapshotStore, :read, 2}, true, [:global])
    :erlang.trace(view.pid, true, [:call])

    try do
      for _ <- 1..20, do: Aiur.AgentPubSub.broadcast_fleet_refresh()

      assert_receive {:trace, pid, :call, {SnapshotStore, :read, _args}}, 2_000
      assert pid == view.pid
      refute_receive {:trace, ^pid, :call, {SnapshotStore, :read, _args}}, 100
    after
      :erlang.trace(view.pid, false, [:call])
      :erlang.trace_pattern({SnapshotStore, :read, 2}, false, [:global])
    end
  end

  test "stale snapshots retain the separately published global pause state" do
    previous = SnapshotCache.get(Aiur.Orchestrator)
    on_exit(fn -> restore_snapshot(Aiur.Orchestrator, previous) end)
    :ok = SnapshotStore.publish(Aiur.Orchestrator, %{running: [], retrying: [], idle: []})
    cached = SnapshotCache.get(Aiur.Orchestrator)
    SnapshotCache.put(Aiur.Orchestrator, %{cached | observed_at_ms: System.monotonic_time(:millisecond) - SnapshotStore.stale_age_ceiling_ms()})

    assert PauseState.pause_state(Aiur.Orchestrator) == false
  end

  test "a stale snapshot without pause state loads during startup without calling its publisher" do
    {:ok, pid} = Agent.start_link(fn -> :unused end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    :ok = SnapshotStore.publish(pid, %{running: [], retrying: [], idle: []})
    cached = SnapshotCache.get(pid)
    SnapshotCache.put(pid, %{cached | observed_at_ms: System.monotonic_time(:millisecond) - SnapshotStore.stale_age_ceiling_ms()})

    assert PauseState.pause_state(pid, 0) == :loading
    assert Process.alive?(pid)
    assert PauseState.pause_state(pid, 600_000) == nil
    assert Process.alive?(pid)
  end

  test "an unpublished live orchestrator stops loading after the startup deadline" do
    {:ok, pid} = StartingOrchestrator.start_link()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert PauseState.pause_state(pid, 0) == :loading
    assert PauseState.pause_state(pid, 600_000) == nil
  end

  test "the pause loading surface leaves loading at its deadline" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, globally_paused: :loading}}

    assert {:noreply, %{assigns: %{globally_paused: nil}}} = PauseState.handle_info(:pause_startup_deadline, socket)
  end

  test "unavailable snapshots render unknown and keep the pause action disabled" do
    assert_unknown_pause_state(:missing_orchestrator)
  end

  test "unpublished daemon snapshot renders a loading pause state" do
    {:ok, pid} = StartingOrchestrator.start_link()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert :loading == PauseState.pause_state(pid)

    html =
      render_component(&DashboardShell.dashboard_shell/1,
        route: RouteRegistry.current_route(:analytics),
        routes: RouteRegistry.routes(%{}),
        tracker_kind: "github",
        agent_kind: "codex",
        inner_block: [],
        pause_state: %{globally_paused: :loading, writable: true, global_pause_error: nil}
      )

    assert html =~ "Loading status"
    refute html =~ "Pause state unknown"
    assert html =~ "disabled"
  end

  test "read-only mode disables the shell toggle and ignores forged events" do
    reconfigure_endpoint(:dashboard_writable, false)
    {:ok, view, html} = live(authorized_conn(), "/analytics")

    assert html =~ "Pause new starts"
    assert has_element?(view, "#ax-pause[disabled]")
    render_click(view, "toggle-global-pause", %{})
    assert {:ok, %{globally_paused: false}} = GlobalPause.global_pause_status()
  end

  defp assert_unknown_pause_state(orchestrator) do
    state = PauseState.pause_state(orchestrator, 600_000)
    assert is_nil(state)

    html =
      render_component(&DashboardShell.dashboard_shell/1,
        route: RouteRegistry.current_route(:analytics),
        routes: RouteRegistry.routes(%{}),
        tracker_kind: "github",
        agent_kind: "codex",
        inner_block: [],
        pause_state: %{globally_paused: state, writable: true, global_pause_error: nil}
      )

    pause = html |> Floki.parse_document!() |> Floki.find("#ax-pause") |> hd()
    assert Floki.text(pause) =~ "Pause state unknown"
    assert Floki.attribute(pause, "disabled") == ["disabled"]
    assert Floki.attribute(pause, "aria-checked") == []
  end

  defp restore_snapshot(orchestrator, nil), do: SnapshotCache.delete(orchestrator)

  defp restore_snapshot(orchestrator, cached) do
    SnapshotStore.publish(orchestrator, cached.snapshot, cached.source_state)
  end

  defp authorized_conn do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)

  defp reconfigure_endpoint(key, value) do
    config = Application.fetch_env!(:aiur, Endpoint) |> Keyword.put(key, value)
    Application.put_env(:aiur, Endpoint, config)
    Endpoint.config_change(%{Endpoint => config}, [])
  end
end
