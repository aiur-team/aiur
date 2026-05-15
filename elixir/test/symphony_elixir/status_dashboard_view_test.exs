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

  test "reconcile_log_view_with_snapshot keeps locally pending composer status when agent becomes paused",
       %{dashboard: dashboard} do
    dashboard =
      dashboard
      |> state()
      |> Map.put(:view, {:log, paused_log_view()})
      |> StatusDashboard.reconcile_log_view_with_snapshot_for_test(paused_snapshot())

    assert %{view: {:log, %{composer: %{pending_request_id: 91}}}} = dashboard
  end

  test "reconcile_log_view_with_snapshot clears local pending once the queue item is visible", %{dashboard: dashboard} do
    dashboard =
      dashboard
      |> state()
      |> Map.put(:view, {:log, paused_log_view()})
      |> StatusDashboard.reconcile_log_view_with_snapshot_for_test(snapshot_with_queued_messages())

    assert %{view: {:log, %{composer: %{pending_request_id: 91, local_pending_messages: []}}}} = dashboard
  end

  test "reconcile_log_view_with_snapshot clears pending once previously visible item is consumed", %{dashboard: dashboard} do
    log_view = %{
      paused_log_view()
      | composer: %{buffer: "", cursor_offset: 0, pending_request_id: 91, last_error: nil, local_pending_messages: []}
    }

    dashboard =
      dashboard
      |> state()
      |> Map.put(:view, {:log, log_view})
      |> StatusDashboard.reconcile_log_view_with_snapshot_for_test(paused_snapshot())

    assert %{view: {:log, %{composer: %{pending_request_id: nil, local_pending_messages: []}}}} = dashboard
  end

  test "append_text renders immediately from cached snapshot despite throttled render interval", %{dashboard: dashboard} do
    workspace = Path.join(System.tmp_dir!(), "status_dashboard_view_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "logs"))

    on_exit(fn -> File.rm_rf!(workspace) end)

    log_view = %{paused_log_view() | workspace_path: workspace, composer: fresh_composer_for_test()}

    :sys.replace_state(dashboard, fn state ->
      %{
        state
        | view: {:log, log_view},
          last_snapshot_data: snapshot_with_workspace(workspace),
          last_tps_value: 0.0,
          last_rendered_at_ms: System.monotonic_time(:millisecond)
      }
    end)

    :ok = StatusDashboard.append_text(dashboard, "a")

    assert_receive {:render, rendered}, 100
    assert rendered =~ "› a"
  end

  test "cursor movement edits at the insertion point", %{dashboard: dashboard} do
    workspace = Path.join(System.tmp_dir!(), "status_dashboard_cursor_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "logs"))

    on_exit(fn -> File.rm_rf!(workspace) end)

    log_view =
      %{paused_log_view() | workspace_path: workspace, composer: fresh_composer_for_test()}

    :sys.replace_state(dashboard, fn state ->
      %{
        state
        | view: {:log, log_view},
          last_snapshot_data: snapshot_with_workspace(workspace),
          last_tps_value: 0.0,
          last_rendered_at_ms: System.monotonic_time(:millisecond)
      }
    end)

    :ok = StatusDashboard.append_text(dashboard, "ac")
    :ok = StatusDashboard.move_cursor_left(dashboard)
    :ok = StatusDashboard.append_text(dashboard, "b")

    assert %{view: {:log, %{composer: %{buffer: "abc", cursor_offset: 2}}}} = state(dashboard)
  end

  test "empty submit does not redraw cached log view", %{dashboard: dashboard} do
    workspace = Path.join(System.tmp_dir!(), "status_dashboard_view_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "logs"))

    on_exit(fn -> File.rm_rf!(workspace) end)

    log_view = %{paused_log_view() | workspace_path: workspace, composer: fresh_composer_for_test()}

    :sys.replace_state(dashboard, fn state ->
      %{
        state
        | view: {:log, log_view},
          last_snapshot_data: snapshot_with_workspace(workspace),
          last_tps_value: 0.0,
          last_rendered_at_ms: System.monotonic_time(:millisecond)
      }
    end)

    :ok = StatusDashboard.submit_message(dashboard)

    refute_receive {:render, _rendered}, 100
  end

  test "reconcile_log_view_with_snapshot keeps queued operator messages on the running entry", %{dashboard: dashboard} do
    dashboard =
      dashboard
      |> state()
      |> Map.put(:view, {:log, paused_log_view()})
      |> StatusDashboard.reconcile_log_view_with_snapshot_for_test(snapshot_with_queued_messages())

    assert %{view: {:log, _log_view}} = dashboard
  end

  test "rendered queued section hides operator messages once they are present in the log" do
    workspace = Path.join(System.tmp_dir!(), "status_dashboard_logged_operator_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "logs"))
    File.write!(Path.join([workspace, "logs", "agent.md"]), operator_log_entry("abc"))

    on_exit(fn -> File.rm_rf!(workspace) end)

    log_view = %{
      paused_log_view()
      | workspace_path: workspace,
        composer: %{buffer: "", cursor_offset: 0, pending_request_id: 91, last_error: nil, local_pending_messages: []}
    }

    rendered =
      snapshot_with_workspace_and_queue(workspace, [%{id: 91, text: "abc", status: :delivered}])
      |> StatusDashboard.format_snapshot_content_for_test(0.0, 100, 0,
        view: {:log, log_view},
        terminal_rows: 40
      )

    assert rendered =~ "Executor"
    assert rendered =~ "abc"
    refute rendered =~ "Queued input"
    refute rendered =~ "queued: abc"
    refute rendered =~ "sending: abc"
    refute rendered =~ "sent; waiting for agent turn"
  end

  test "rendered log view keeps a blank separator between the running table and log pane" do
    workspace = Path.join(System.tmp_dir!(), "status_dashboard_separator_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "logs"))

    on_exit(fn -> File.rm_rf!(workspace) end)

    rendered =
      snapshot_with_workspace(workspace)
      |> StatusDashboard.format_snapshot_content_for_test(0.0, 100, 0,
        view: {:log, %{paused_log_view() | workspace_path: workspace}},
        terminal_rows: 40
      )

    assert rendered =~ "\n│\n\e[1m├─ Agent log:"
  end

  test "interactive log view keeps the last running snapshot while a submitted message is still pending" do
    previous_snapshot = snapshot_with_workspace("/tmp/mt-251")

    current_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    assert ^previous_snapshot =
             StatusDashboard.renderable_snapshot_data_for_test(
               current_snapshot,
               previous_snapshot,
               {:log, paused_log_view()}
             )
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
      composer: %{
        buffer: "",
        cursor_offset: 0,
        pending_request_id: 91,
        last_error: nil,
        local_pending_messages: [%{id: 91, text: "abc", status: :pending}]
      }
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

  defp snapshot_with_workspace(workspace) do
    snapshot_with_workspace_and_queue(workspace, [])
  end

  defp snapshot_with_workspace_and_queue(workspace, pending_operator_messages) do
    {:ok,
     %{
       running: [
         %{
           identifier: "MT-251",
           title: "Pause and resume",
           workspace_path: workspace,
           runtime_seconds: 0,
           turn_count: 0,
           state: "running",
           work_state: :working,
           control: %{status: :working},
           pending_operator_messages: pending_operator_messages
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
             %{id: 91, text: "abc", status: :pending},
             %{id: 2, text: "def", status: :delivered}
           ]
         }
       ],
       retrying: [],
       agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
       rate_limits: nil
     }}
  end

  defp fresh_composer_for_test do
    %{buffer: "", cursor_offset: 0, pending_request_id: nil, last_error: nil, local_pending_messages: []}
  end

  defp operator_log_entry(text) do
    payload =
      Jason.encode!(%{
        "method" => "item/started",
        "params" => %{
          "item" => %{
            "type" => "userMessage",
            "content" => [%{"text" => text}]
          }
        }
      })

    """
    ## 2026-05-10T22:46:39.307486Z notification

    ```text
    #{payload}
    ```


    """
  end
end
