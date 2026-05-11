defmodule SymphonyElixir.StatusDashboardViewTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.StatusDashboard

  setup do
    parent = self()

    {:ok, pid} =
      StatusDashboard.start_link(
        name: :"status_dashboard_view_test_#{System.unique_integer([:positive])}",
        enabled: true,
        refresh_ms: 100_000,
        render_interval_ms: 100_000,
        render_fun: fn content -> send(parent, {:render, content}) end,
        selected_index: 0
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, dashboard: pid}
  end

  describe "open_log/close_log/scroll_log casts" do
    test "open_log is a no-op when state is :list with no running entries", %{dashboard: dashboard} do
      :ok = StatusDashboard.open_log(dashboard)
      assert state(dashboard).view == :list
    end

    test "close_log is a no-op when state is :list", %{dashboard: dashboard} do
      :ok = StatusDashboard.close_log(dashboard)
      assert state(dashboard).view == :list
    end

    test "scroll_log_up is a no-op when state is :list", %{dashboard: dashboard} do
      :ok = StatusDashboard.scroll_log_up(dashboard)
      assert state(dashboard).view == :list
    end

    test "scroll_log_down is a no-op when state is :list", %{dashboard: dashboard} do
      :ok = StatusDashboard.scroll_log_down(dashboard)
      assert state(dashboard).view == :list
    end
  end

  defp state(dashboard) do
    :sys.get_state(dashboard)
  end
end
