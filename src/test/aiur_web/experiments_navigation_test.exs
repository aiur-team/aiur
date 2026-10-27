defmodule AiurWeb.ExperimentsNavigationTest do
  use ExUnit.Case, async: true

  test "navigation derives experiment availability from the capability report" do
    table = :ets.new(:experiments_navigation, [:set])

    for {state, expected} <- [{:available, true}, {:degraded, true}, {:unavailable, false}, {:unknown, false}] do
      :ets.insert(table, {:report, {%{capabilities: %{"experiments" => %{state: state}}}, System.monotonic_time(:millisecond), nil}})
      navigation = AiurWeb.Presenter.analytics_navigation(table: table, telemetry_file_fun: fn -> nil end)
      assert navigation.experiments_available? == expected
    end

    :ets.insert(table, {:report, {%{capabilities: %{}}, System.monotonic_time(:millisecond), nil}})
    refute AiurWeb.Presenter.analytics_navigation(table: table).experiments_available?
  end

  test "Units payload keeps the same nav items as pages reading the navigation directly" do
    alias AiurWeb.OperatorControlCenter.RouteRegistry

    navigation = %{available?: false, path: nil, message: "none", experiments_available?: true}
    payload = AiurWeb.ControlCenterPresenter.compose(%{analytics: navigation}, [], [], %{merges: [], health: :ready})

    assert Enum.map(RouteRegistry.routes(payload.analytics), & &1.id) == Enum.map(RouteRegistry.routes(navigation), & &1.id)
    assert {:ok, _route} = RouteRegistry.route(:experiments, payload.analytics)
  end

  test "experiment routes use their own session with the dashboard gate and authentication" do
    for {path, action} <- [{"/experiments", :experiments}, {"/experiments/:id", :experiment}] do
      route = Enum.find(AiurWeb.Router.__routes__(), &(&1.path == path))
      assert route.plug == Phoenix.LiveView.Plug
      assert route.plug_opts == action
      {AiurWeb.ExperimentsLive, ^action, _, session} = route.metadata.phoenix_live_view
      assert session.name == :experiments
      assert Enum.map(session.extra.on_mount, &elem(&1.id, 0)) == [AiurWeb.DashboardPagesGate, AiurWeb.FinancialDataAccess]
      info = Phoenix.Router.route_info(AiurWeb.Router, "GET", String.replace(path, ":id", "example"), "localhost")
      assert info.pipe_through == [:browser_dashboard_auth, :dashboard_pages, :browser]
    end
  end
end
