defmodule AiurWeb.DashboardLive.GlobalPauseTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.CountingOrchestrator
  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.GlobalPauseFailureOrchestrator

  @endpoint AiurWeb.Endpoint

  describe "global pause nav toggle" do
    test "keeps a persisted global pause visible on a stale snapshot before the first restart poll" do
      orchestrator_name = Module.concat(__MODULE__, :RestartedGlobalPauseOrchestrator)

      snapshot = %{
        running: [],
        retrying: [],
        idle: [],
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil,
        globally_paused: false
      }

      {:ok, original} = CountingOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      assert :ok = GenServer.stop(original, :normal)

      {:ok, restarted} =
        CountingOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot, publish?: false)

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(restarted)
      end)

      generation = SnapshotStore.begin_generation(orchestrator_name)

      :ok =
        SnapshotStore.publish_global_pause(orchestrator_name, generation, %{
          globally_paused: true,
          paused_at: ~U[2026-08-02 12:00:00Z],
          source: "dashboard"
        })

      assert {:stale, %{globally_paused: true}, %{reason: :orchestrator_unavailable}} =
               Orchestrator.dashboard_snapshot(orchestrator_name, 100)

      start_test_endpoint(orchestrator: orchestrator_name, dashboard_writable: true)
      {:ok, _view, html} = live(build_conn(), "/units")

      assert html =~ "ax-mi aiur-shell__menu-item on"
      assert html =~ ~s(aria-checked="true")
      assert html =~ "Resume new starts"
      refute html =~ "global-pause-banner"
    end

    test "fleet errors render unknown pause rather than an off switch" do
      for fleet <- [%{error: %{code: "orchestrator_unavailable", message: "Daemon unavailable"}}, Map.delete(global_pause_fleet(false), :globally_paused)] do
        doc = fleet |> render_payload(writable: true) |> Floki.parse_document!()
        item = Floki.find(doc, "#ax-pause")
        assert Floki.text(item) =~ "Pause state unknown"
        assert Floki.attribute(item, "disabled") == ["disabled"]
        assert Floki.attribute(item, "aria-checked") == []
        assert Floki.find(item, ".ax-sw") == []
        assert Floki.find(doc, "#ax-paused.show") == []
      end
    end

    test "future regression guard: a forged read-only pause event does not reach the orchestrator" do
      orchestrator_name = Module.concat(__MODULE__, :ReadOnlyGlobalPauseOrchestrator)
      start_supervised!({GlobalPauseFailureOrchestrator, name: orchestrator_name, report: self()})
      start_test_endpoint(orchestrator: orchestrator_name, dashboard_writable: false)
      {:ok, view, _html} = live(build_conn(), "/units")
      render_click(view, "toggle-global-pause")
      refute_received {:global_pause_attempt, _, _}
      assert view |> element("#ax-pause") |> render() =~ ~s(aria-checked="false")
    end

    test "renders a pause affordance while the daemon is running and writable" do
      html = render_payload(global_pause_fleet(false), writable: true)

      assert html =~ ~s(id="ax-pause")
      assert html =~ ~s(phx-click="toggle-global-pause")
      assert html =~ ~s(aria-checked="false")
      assert html =~ "Pause new starts"
      refute html =~ "ax-mi aiur-shell__menu-item on"
      refute html =~ ~s|aria-label="Resume new starts"|
    end

    test "renders a resume affordance while the daemon is globally paused" do
      html = render_payload(global_pause_fleet(true), writable: true)

      assert html =~ "ax-mi aiur-shell__menu-item on"
      assert html =~ ~s(aria-checked="true")
      assert html =~ "Resume new starts"
      refute html =~ "global-pause-banner"
      refute html =~ "lift the global pause"
    end

    test "surfaces a persistence error without claiming the toggle changed" do
      html =
        render_payload(global_pause_fleet(false),
          writable: true,
          global_pause_error: "Global pause was not changed because its state could not be persisted."
        )

      assert html =~ ~s(class="readonly-banner global-pause-error")
      assert html =~ "state could not be persisted"
    end

    test "surfaces a persistence failure returned by the real toggle event" do
      orchestrator_name = Module.concat(__MODULE__, :GlobalPauseFailureOrchestrator)

      start_supervised!({GlobalPauseFailureOrchestrator, name: orchestrator_name, report: self()})

      start_test_endpoint(orchestrator: orchestrator_name, dashboard_writable: true)
      {:ok, view, _html} = live(build_conn(), "/units")

      html = view |> element("#ax-pause") |> render_click()

      receive_barrier({:global_pause_attempt, true, "dashboard"})
      assert html =~ "state could not be persisted"
      assert html =~ "The daemon remains in its previous state"
      assert html =~ ~s(aria-checked="false")
    end

    test "disables the toggle when the dashboard is read-only" do
      html = render_payload(global_pause_fleet(false), writable: false)

      assert html =~ ~s(id="ax-pause")
      assert html =~ ~s(aria-disabled="true")
      assert html =~ "disabled"
    end

    test "places one pause, theme and palette control in the settings menu for both layouts" do
      doc = global_pause_fleet(false) |> render_payload(writable: true) |> Floki.parse_document!()
      assert Floki.find(doc, ".ax-top .ax-brand #ax-menu #ax-pause") != []
      assert Floki.find(doc, "aside.sidenav #theme-toggle") == []
      assert length(Floki.find(doc, "#ax-menu [phx-hook=\"ThemeToggle\"]")) == 1
      assert length(Floki.find(doc, "#ax-menu [phx-hook=\"PaletteToggle\"][aria-checked=\"true\"]")) == 1

      for id <- ~w(ax-pause theme-toggle ax-palette) do
        assert length(Floki.find(doc, "##{id}")) == 1, "duplicate DOM id: #{id}"
      end
    end

    test "the topbar carries no clock" do
      doc =
        global_pause_fleet(false)
        |> render_payload(writable: true)
        |> Floki.parse_document!()

      assert Floki.find(doc, ".ax-top time") == []
    end

    test "the shared menu pause item mirrors paused state and read-only gating" do
      paused = render_payload(global_pause_fleet(true), writable: true)
      mobile_paused = paused |> Floki.parse_document!() |> Floki.find("#ax-pause")

      assert Floki.attribute(mobile_paused, "aria-checked") == ["true"]
      assert Floki.attribute(mobile_paused, "class") |> List.first() =~ "on"

      readonly = render_payload(global_pause_fleet(false), writable: false)
      mobile_readonly = readonly |> Floki.parse_document!() |> Floki.find("#ax-pause")

      assert Floki.attribute(mobile_readonly, "aria-disabled") == ["true"]
    end

    # SVG wrappers carry no intrinsic dimensions; guard their shared sizing rules.
    test "every icon wrapper in the shell has an svg sizing rule" do
      css = File.read!(Application.app_dir(:aiur, "priv/static/aiur-style/css/dashboard-shell.css"))

      wrapper_classes =
        global_pause_fleet(false)
        |> render_payload(writable: true)
        |> Floki.parse_document!()
        |> Floki.find("#ax-frame .snav-ic, #ax-frame .toggle-icon")
        |> Enum.flat_map(&Floki.attribute([&1], "class"))
        |> Enum.flat_map(&String.split/1)
        |> Enum.filter(&String.starts_with?(&1, "aiur-"))
        |> Enum.uniq()

      assert wrapper_classes != [], "expected the shell to render icon wrappers"

      for class <- wrapper_classes do
        assert Regex.match?(~r/\.#{Regex.escape(class)}\s+svg\s*\{[^}]*\bwidth\s*:/, css),
               "#{class} renders an inline SVG but dashboard.css has no `.#{class} svg { width: ... }` rule, so it collapses to nothing"
      end
    end
  end
end
