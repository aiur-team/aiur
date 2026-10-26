defmodule AiurWeb.DashboardLive.ConversationTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias Aiur.Agent.UsageSnapshotService

  @endpoint AiurWeb.Endpoint

  test "opens a read-only conversation drawer from the explicit action and closes it truthfully" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("a")
    orchestrator_name = Module.concat(__MODULE__, :ConversationOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    usage_snapshot = units_conversation_snapshot(identity, handle)

    running_with_context =
      usage_snapshot.running
      |> hd()
      |> Map.merge(%{
        telemetry_attempt_id: "attempt-1110",
        context_usage: %{used_tokens: 1200, window_tokens: 4000, used_percent: 30.0, pressure: :warning}
      })

    replace_counting_snapshot(orchestrator, %{usage_snapshot | running: [running_with_context]})

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn resolved ->
        send(test_pid, {:conversation_resolved, resolved})
        {:ok, conversation_snapshot(handle)}
      end,
      live_conversation_subscribe_fun: fn resolved ->
        send(test_pid, {:conversation_subscribed, resolved})
        :ok
      end,
      live_conversation_unsubscribe_fun: fn resolved ->
        send(test_pid, {:conversation_unsubscribed, resolved})
        :ok
      end,
      usage_snapshot_fun: fn agent_id, opts ->
        UsageSnapshotService.current(
          agent_id,
          Keyword.merge(opts,
            cells_snapshot_fun: fn -> %{cells: attempt_usage_cells(identity), metadata: %{source_position: 1}} end,
            ledger_scan_fun: fn _scan_opts -> {:ok, [attempt_usage_record(identity)]} end
          )
        )
      end
    )

    {:ok, view, html} = live(build_conn(), "/units")
    assert html =~ "Open chat"
    refute html =~ "units-conversation-drawer"

    html =
      view
      |> element(~s(button[phx-click="read-conversation"]))
      |> render_click()

    assert_receive {:conversation_resolved, ^handle}, 1000
    assert_receive {:conversation_subscribed, ^handle}, 1000
    assert html =~ ~s(id="units-conversation-drawer")
    assert html =~ "You can read this conversation here. Sending is not available."
    assert html =~ "Read-only dashboard — use the TUI to message or pause this agent."
    refute html =~ "Read-only mirror"
    assert html =~ "its-everdred/aiur #1110"
    assert html =~ "Reviewing the drawer"
    assert html =~ "1200 / 4000 tokens (30%) · warning"
    assert html =~ "Current attempt"
    assert html =~ "150"
    refute html =~ handle
    refute html =~ "units-ticket-context"

    view |> element(~s(#units-conversation-drawer button), "Close") |> render_click()
    assert_receive {:conversation_unsubscribed, ^handle}, 1000
    refute has_element?(view, "#units-conversation-drawer")
  end

  test "ordinary row inspection opens ticket context, not the conversation drawer" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("b")
    orchestrator_name = Module.concat(__MODULE__, :ConversationRegressionOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      ticket_detail_request_fun: fn selected ->
        {:ok, units_ticket_detail(selected, "Responsive Units interface")}
      end,
      ticket_history_request_fun: fn selected -> {:ok, units_ticket_history(selected)} end,
      live_conversation_resolve_fun: fn _handle ->
        send(test_pid, :unexpected_resolve)
        {:ok, conversation_snapshot(handle)}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/units")

    html = view |> element(~s(td.ut-id-cell[phx-click="inspect-unit"])) |> render_click()

    assert html =~ ~s(id="units-ticket-context")
    refute html =~ ~s(id="units-conversation-drawer")
    refute_receive :unexpected_resolve, 100
  end

  test "the conversation drawer replaces only the pinned generation and ignores other handles" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("c")
    other_handle = conversation_handle_value("d")
    orchestrator_name = Module.concat(__MODULE__, :ConversationUpdateOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _handle -> :ok end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    view |> element(~s(button[phx-click="read-conversation"])) |> render_click()

    send(
      view.pid,
      {:live_conversation_changed, conversation_snapshot(handle, message_body: "Fresh pinned update")}
    )

    assert render(view) =~ "Fresh pinned update"

    send(
      view.pid,
      {:live_conversation_changed, conversation_snapshot(other_handle, message_body: "Replacement worker")}
    )

    html = render(view)
    assert html =~ "Fresh pinned update"
    refute html =~ "Replacement worker"
  end

  test "a projection restart freezes the open conversation drawer as superseded" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("e")
    orchestrator_name = Module.concat(__MODULE__, :ConversationRestartOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _handle -> :ok end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    view |> element(~s(button[phx-click="read-conversation"])) |> render_click()

    send(view.pid, {:live_conversation_restarted, "epoch-2", ~U[2026-07-17 13:00:00Z]})

    assert render(view) =~ "Superseded"
  end
end
