defmodule AiurWeb.DashboardLive.AgentLogTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @endpoint AiurWeb.Endpoint

  test "Agent log writable actions carry the selected typed Unit identity" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :TypedAgentLogOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      agent_chat_send_fun: fn selected, text ->
        send(test_pid, {:typed_agent_message, selected, text})
        {:ok, 7}
      end,
      agent_chat_pause_fun: fn selected ->
        send(test_pid, {:typed_agent_pause, selected})
        {:ok, 8}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    token = UnitsPresenter.row_token(%{identity: identity})

    html =
      render_hook(view, "show-agent-log", %{"unit" => token})

    assert html =~ ~s(phx-submit="send-operator-message")

    render_submit(view, "send-operator-message", %{"message" => "typed hello"})
    assert_receive {:typed_agent_message, ^identity, "typed hello"}, 1000

    render_hook(view, "pause-agent", %{})
    assert_receive {:typed_agent_pause, ^identity}, 1000
  end

  test "Agent log send keeps its message id for a retry after an unknown outcome" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :RetryAgentLogOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()
    replies = :counters.new(1, [])

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      agent_chat_send_fun: fn _selected, text, opts ->
        send(test_pid, {:retry_agent_message, text, Keyword.fetch!(opts, :message_id)})
        :counters.add(replies, 1, 1)

        if :counters.get(replies, 1) <= 2,
          do: {:error, {:outcome_unknown, %{message_id: Keyword.fetch!(opts, :message_id), item_id: nil}}},
          else: {:ok, 7}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    render_hook(view, "show-agent-log", %{"unit" => UnitsPresenter.row_token(%{identity: identity})})

    html = render_submit(view, "send-operator-message", %{"message" => "continue"})
    assert_receive {:retry_agent_message, "continue", first_id}, 1000
    assert html =~ "may still be queued"

    # An edited draft is a new message, so it gets a fresh id.
    render_submit(view, "send-operator-message", %{"message" => "continue, please"})
    assert_receive {:retry_agent_message, "continue, please", edited_id}, 1000
    refute edited_id == first_id

    # Send again with the same draft retries it under the kept id.
    render_submit(view, "send-operator-message", %{"message" => "continue, please"})
    assert_receive {:retry_agent_message, "continue, please", ^edited_id}, 1000

    # After a success, the same text is a new message.
    render_submit(view, "send-operator-message", %{"message" => "continue, please"})
    assert_receive {:retry_agent_message, "continue, please", fourth_id}, 1000
    refute fourth_id in [first_id, edited_id]
  end

  test "the chat modal composer carries the writable agent log and passes the typed Unit identity" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("c")
    orchestrator_name = Module.concat(__MODULE__, :TypedConversationComposerOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    snapshot = units_orchestrator_snapshot(identity)

    running =
      snapshot.running
      |> hd()
      |> Map.merge(%{
        live_conversation: %{generation_handle: handle, state: :live, health: :healthy, freshness: :current},
        workspace_path: Path.join(System.tmp_dir!(), "units-chat-composer-log")
      })

    replace_counting_snapshot(orchestrator, %{snapshot | running: [running]})

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _handle -> :ok end,
      agent_chat_send_fun: fn selected, text ->
        send(test_pid, {:drawer_agent_message, selected, text})
        {:ok, 9}
      end,
      agent_chat_pause_fun: fn selected ->
        send(test_pid, {:drawer_agent_pause, selected})
        {:ok, 10}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/units")

    html = view |> element(~s(button[phx-click="read-conversation"])) |> render_click()

    assert html =~ ~s(phx-submit="send-operator-message")
    assert html =~ "Agent log"

    render_submit(view, "send-operator-message", %{"message" => "drawer hello"})
    assert_receive {:drawer_agent_message, ^identity, "drawer hello"}, 1000

    render_hook(view, "pause-agent", %{})
    assert_receive {:drawer_agent_pause, ^identity}, 1000
  end

  test "Agent log disables and rejects writes for colliding display identifiers" do
    alpha = units_identity()
    beta = units_identity(repository: "other", provider_id: "NODE-other-1110")
    membership = units_membership(alpha)
    membership = %{membership | members: membership.members ++ units_membership(beta).members}
    orchestrator_name = Module.concat(__MODULE__, :CollidingAgentLogOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    alpha_row = units_orchestrator_snapshot(alpha).running |> hd()
    beta_row = units_orchestrator_snapshot(beta).running |> hd() |> Map.put(:issue_id, "issue-other-1110")

    snapshot = %{units_orchestrator_snapshot(alpha) | running: [alpha_row, beta_row]}
    replace_counting_snapshot(orchestrator, snapshot)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(alpha) end,
      agent_chat_send_fun: fn selected, text ->
        send(test_pid, {:unexpected_agent_message, selected, text})
        {:ok, 9}
      end,
      agent_chat_pause_fun: fn selected ->
        send(test_pid, {:unexpected_agent_pause, selected})
        {:ok, 10}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    token = UnitsPresenter.row_token(%{identity: alpha})

    html =
      render_hook(view, "show-agent-log", %{"unit" => token})

    assert html =~ "not a unique writable target"
    refute html =~ ~s(phx-submit="send-operator-message")
    refute html =~ ~s(phx-click="pause-agent")

    render_submit(view, "send-operator-message", %{"message" => "must not route"})
    render_hook(view, "pause-agent", %{})
    refute_receive {:unexpected_agent_message, _identity, _text}, 100
    refute_receive {:unexpected_agent_pause, _identity}, 100
  end
end
