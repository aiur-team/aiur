defmodule AiurWeb.DashboardLive.UnitControlsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.ControlFixtures
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @endpoint AiurWeb.Endpoint

  describe "unit controls (DASH-005)" do
    test "pauses an eligible unit through DASH-004 and mirrors applied evidence only" do
      %{view: view, token: token} =
        start_unit_control(:PauseAppliedOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_caps, "1110"}, 1000
      assert_receive {:unit_pause, "1110"}, 1000
      assert html =~ "Pause requested"
      refute html =~ "tone-applied"

      send(view.pid, {:control_lifecycle, lifecycle(:pause, :applied, 8)})
      html = render(view)
      assert html =~ "Paused"
      assert html =~ "tone-applied"
      # The control button keeps its stable id across the lifecycle re-render, so
      # LiveView preserves keyboard focus on it.
      assert html =~ ~s(id="units-control-#{token}")
    end

    test "resumes an applied-paused unit and correlates the resume lifecycle" do
      %{view: view, token: token} =
        start_unit_control(:ResumeOrchestrator,
          work_state: :paused,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :paused, pending_control: nil}} end,
          resume: {:ok, :resumed}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "resume"})
      assert_receive {:unit_resume, "1110"}, 1000
      assert html =~ "Resume requested"

      send(view.pid, {:control_lifecycle, lifecycle(:resume, :applied, 21)})
      assert render(view) =~ "Resumed"
    end

    test "fails closed and never invokes DASH-004 when the dashboard is read-only" do
      %{view: view, token: token, html: html} =
        start_unit_control(:ReadOnlyControlOrchestrator,
          writable: false,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      assert html =~ ~s(aria-disabled="true")
      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_caps, _}, 100
      refute_receive {:unit_pause, _}, 100
    end

    test "debounces duplicate activation while a request is pending" do
      %{view: view, token: token} =
        start_unit_control(:DebounceOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_caps, "1110"}, 1000
      assert_receive {:unit_pause, "1110"}, 1000

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, "1110"}, 100
      refute_receive {:unit_caps, "1110"}, 100
    end

    test "renders request-only distinctly and does not invoke the owner" do
      %{view: view, token: token} =
        start_unit_control(:RequestOnlyOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :request_only, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_caps, "1110"}, 1000
      refute_receive {:unit_pause, _}, 100
      assert html =~ "request-only"
      refute html =~ "tone-applied"
    end

    test "an unsupported worker is visibly distinct and never invoked" do
      %{view: view, token: token} =
        start_unit_control(:UnsupportedOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :unsupported, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, _}, 100
      assert html =~ "unsupported"
    end

    test "a concurrent state change cancels the request without invoking the owner" do
      %{view: view, token: token} =
        start_unit_control(:StateChangeOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :paused, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, _}, 100
      assert html =~ "state changed"
    end

    test "a stale-generation rejection cancels stale intent rather than masquerading as applied" do
      %{view: view, token: token} =
        start_unit_control(:StaleGenerationOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_pause, "1110"}, 1000

      send(view.pid, {:control_lifecycle, lifecycle(:pause, :rejected, 8, %{class: :stale_generation})})
      html = render(view)
      refute html =~ "tone-applied"
      assert html =~ "canceled"
    end

    test "a concurrent terminal transition cancels stale in-flight intent on reload" do
      identity = units_identity()
      orchestrator_name = Module.concat(__MODULE__, :TerminalReconcileOrchestrator)
      orchestrator = start_counting_orchestrator(orchestrator_name)
      test_pid = self()
      {:ok, membership_agent} = Agent.start_link(fn -> units_membership(identity) end)

      replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

      start_test_endpoint(
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 100,
        control_center_cache: false,
        dashboard_writable: true,
        units_membership_fun: fn -> Agent.get(membership_agent, & &1) end,
        units_activity_fun: fn -> units_activity(identity) end,
        agent_chat_capabilities_fun: fn _id ->
          {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}}
        end,
        agent_chat_pause_fun: fn id ->
          send(test_pid, {:unit_pause, id})
          {:ok, 8}
        end
      )

      {:ok, view, _html} = live(build_conn(), "/units")
      token = UnitsPresenter.row_token(%{identity: identity})

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_pause, "1110"}, 1000
      assert render(view) =~ "Pause requested"
      assert control_status(view, token) == :requested

      # The unit goes terminal before any applied evidence arrives; a reload must
      # cancel the stale intent rather than let it settle or masquerade as applied.
      terminal = put_in(units_membership(identity), [:members, Access.at(0), :terminal?], true)
      Agent.update(membership_agent, fn _prev -> terminal end)
      send(view.pid, :reload_payload)
      _ = render(view)

      assert control_status(view, token) == :state_changed
    end

    test "a timeout leaves the last state visible with a named retry" do
      %{view: view, token: token} =
        start_unit_control(:TimeoutOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_pause, "1110"}, 1000

      send(view.pid, {:control_lifecycle, lifecycle(:pause, :expired, 8)})
      html = render(view)
      assert html =~ "timed out"
      assert html =~ "tone-error"
    end

    test "a control provider failure surfaces a named error and safe retry" do
      %{view: view, token: token} =
        start_unit_control(:ProviderFailureOrchestrator,
          capabilities: fn -> {:error, :unavailable} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, _}, 100
      assert html =~ "retry"
      assert html =~ "tone-error"
    end
  end
end
