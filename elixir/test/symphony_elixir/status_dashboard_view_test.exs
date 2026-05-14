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

  test "reconcile_log_view_with_snapshot clears pending composer status once the open agent becomes paused",
       %{dashboard: dashboard} do
    dashboard =
      dashboard
      |> state()
      |> Map.put(:view, {:log, paused_log_view()})
      |> StatusDashboard.reconcile_log_view_with_snapshot_for_test(paused_snapshot())

    assert %{view: {:log, %{composer: %{pending_request_id: nil}}}} = dashboard
  end

  test "reconcile_log_view_with_snapshot keeps queued operator messages on the running entry", %{dashboard: dashboard} do
    dashboard =
      dashboard
      |> state()
      |> Map.put(:view, {:log, paused_log_view()})
      |> StatusDashboard.reconcile_log_view_with_snapshot_for_test(snapshot_with_queued_messages())

    assert %{view: {:log, _log_view}} = dashboard
  end

  defp state(dashboard) do
    :sys.get_state(dashboard)
  end

  defp paused_log_view do
    %{
      issue_identifier: "MT-251",
      workspace_path: nil,
      title: nil,
      scroll: 0,
      last_total_lines: 0,
      mode: :typing,
      composer: %{buffer: "", pending_request_id: 91, last_error: nil}
    }
  end

  defp paused_snapshot do
    {:ok,
     %{
       running: [
         %{
           identifier: "MT-251",
           title: "Pause and resume",
           workspace_path: "/tmp/mt-251",
           work_state: :paused,
           control: %{status: :paused}
         }
       ],
       retrying: [],
       agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
       rate_limits: nil
     }}
  end

  defp snapshot_with_queued_messages do
    {:ok,
     %{
       running: [
         %{
           identifier: "MT-251",
           title: "Pause and resume",
           workspace_path: "/tmp/mt-251",
           work_state: :working,
           control: %{status: :working},
           pending_operator_messages: [
             %{id: 1, text: "abc", status: :pending},
             %{id: 2, text: "def", status: :delivered}
           ]
         }
       ],
       retrying: [],
       agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
       rate_limits: nil
     }}
  end
end
