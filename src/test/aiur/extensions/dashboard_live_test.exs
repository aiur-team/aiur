defmodule Aiur.Extensions.DashboardLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  @endpoint AiurWeb.Endpoint
  alias Aiur.Orchestrator.SnapshotStore
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

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    log_root = Aiur.TestSupport.tmp_root!("aiur-dashboard-log")
    log_dir = Path.join(log_root, "logs")
    File.mkdir_p!(log_dir)

    File.write!(
      Path.join(log_dir, "agent.md"),
      """
      ## 2026-05-10T03:48:24Z notification

      ```text
      {"method":"item/started","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"hello from workspace log"}]}}}
      ```

      ## 2026-05-10T03:48:31Z notification

      ```text
      {"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":"working "}}
      ```

      ## 2026-05-10T03:48:32Z notification

      ```text
      {"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":"now"}}
      ```

      ## 2026-05-10T03:48:33Z notification

      ```text
      {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg-1","text":"working now"}}}
      ```
      """
    )

    {snapshot, units_membership} =
      static_snapshot(workspace_path: log_root)
      |> with_static_units()

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      units_membership_fun: fn -> units_membership end,
      units_activity_fun: &static_units_activity/0
    )

    {:ok, view, html} = live(build_conn(), "/units?v=1&scope=unfinished")
    assert html =~ "Units"
    assert Floki.parse_document!(html) |> Floki.find("title") |> Floki.text() =~ "Dashboard"
    assert html =~ "1100"
    assert html =~ "1101"
    assert html =~ "Progress"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    refute html =~ "Latest evidence"
    # The standalone read-agent-log row action moved into the chat modal, so the
    # Units row no longer carries a show-agent-log button.
    refute html =~ "phx-click=\"show-agent-log\""
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    refute html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
    assert html =~ ~s(id="ax-drag")
    assert html =~ ~s(phx-hook="NavToggle")

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "1100",
          tracker_identity: static_units_identity("1100"),
          state: "In Progress",
          title: "Updated unit title",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          workspace_path: log_root,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          agent_input_tokens: 10,
          agent_output_tokens: 12,
          agent_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    :ok = SnapshotStore.publish(orchestrator_name, updated_snapshot)

    AiurWeb.ObservabilityPubSub.broadcast_update()

    assert_eventually(fn -> render(view) =~ "Updated unit title" end, 200)

    token = UnitsPresenter.row_token(%{identity: static_units_identity("1100")})

    # The Units row no longer has a standalone agent-log button (the chat modal
    # carries the log now), so drive the AgentLogModal event handler directly.
    log_html = render_hook(view, "show-agent-log", %{"unit" => token})

    assert log_html =~ "Logs"
    assert log_html =~ "1100"
    assert log_html =~ "data-agent-log-live"
    assert log_html =~ "Live"
    assert log_html =~ "phx-hook=\"AgentLogPanel\""
    assert log_html =~ "phx-click-away=\"close-agent-log\""
    refute log_html =~ "modal-panel\" onclick=\"event.stopPropagation()\""
    assert log_html =~ "Executor"
    assert log_html =~ "hello from workspace log"
    assert log_html =~ "working now"
    assert length(Regex.scan(~r/working now/, log_html)) == 1
    assert log_html =~ "log-message-assistant"
    assert log_html =~ Path.join(log_root, "logs/agent.md")

    File.write!(
      Path.join(log_dir, "agent.md"),
      """

      ## 2026-05-10T03:48:35Z notification

      ```text
      {"method":"item/completed","params":{"item":{"type":"agentMessage","text":"fresh modal update"}}}
      ```
      """,
      [:append]
    )

    AiurWeb.ObservabilityPubSub.broadcast_update()

    assert_eventually(fn -> render(view) =~ "fresh modal update" end, 200)

    closed_html =
      view
      |> element("button", "Close")
      |> render_click()

    refute closed_html =~ "hello from workspace log"
  end
end
