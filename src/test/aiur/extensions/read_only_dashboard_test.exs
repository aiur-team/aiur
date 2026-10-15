defmodule Aiur.Extensions.ReadOnlyDashboardTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  @endpoint AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  import Aiur.ExtensionsTestSupport
  alias Aiur.ExtensionsTestSupport.StaticOrchestrator

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "read-only dashboard liveview hides chat controls and no-ops write events" do
    orchestrator_name = Module.concat(__MODULE__, :ReadOnlyDashboardOrchestrator)
    {snapshot, units_membership} = static_snapshot() |> with_static_units()

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: false,
      units_membership_fun: fn -> units_membership end,
      units_activity_fun: &static_units_activity/0
    )

    {:ok, view, _html} = live(build_conn(), "/")

    token = UnitsPresenter.row_token(%{identity: static_units_identity("1100")})

    modal_html = render_hook(view, "show-agent-log", %{"unit" => token})

    # The agent log modal still opens (reads work), but the composer and its
    # Send/Pause controls are gone — replaced by the read-only notice.
    assert modal_html =~ "Read-only dashboard"
    refute modal_html =~ "agent-chat-send"
    refute modal_html =~ "phx-submit=\"send-operator-message\""
    refute modal_html =~ "phx-click=\"pause-agent\""

    # Defense-in-depth: even a crafted client pushing the write events is a
    # no-op — the guarded clauses fall through and the view stays alive.
    assert render_hook(view, "send-operator-message", %{"message" => "hello"}) =~ "Read-only dashboard"
    assert render_hook(view, "pause-agent", %{}) =~ "Read-only dashboard"
    assert Process.alive?(view.pid)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "No fleet data"
    assert html =~ "orchestrator_unavailable"
    # The presenter still carries the unpublished wording for other codes; an
    # unreachable Orchestrator must never borrow it.
    refute html =~ "No fleet snapshot published yet"
  end
end
