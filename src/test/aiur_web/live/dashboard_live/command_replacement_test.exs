defmodule AiurWeb.DashboardLive.CommandReplacementTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes
  alias Aiur.{Decision, DecisionStore}
  @endpoint AiurWeb.Endpoint

  setup do
    store_name = Module.concat(__MODULE__, Store)
    store = start_decision_store(store_name, fn _, _ -> {:error, :no_running_agent} end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end)
    orchestrator = Module.concat(__MODULE__, Orchestrator)
    start_counting_orchestrator(orchestrator)
    start_test_endpoint(orchestrator: orchestrator, decision_store: store_name, dashboard_writable: true, control_center_cache: false)

    decision =
      request_dashboard_decision(store, "replace", "reversible",
        decision_authority: :supervisor_allowed,
        ticket: %{identifier: "987", title: "Replace", url: "https://github.com/owner/repo/issues/987"}
      )

    %{store: store, decision: decision}
  end

  test "confirmed replace records an operator revision through the dashboard", ctx do
    answered = answer(ctx, :executor)
    {:ok, view, html} = live(build_conn(), "/commands/#{answered.decision_id}")
    assert html =~ "Already answered by the Executor"
    assert has_element?(view, "button[data-confirm=\"Replace the Executor's answer? It has not reached #987 yet.\"]")
    view |> element("button[phx-click=begin-replace-decision]") |> render_click()
    empty_response = view |> element("form[phx-submit=replace-decision] textarea") |> render() |> Floki.parse_fragment!() |> Floki.text()
    assert empty_response == ""
    refute has_element?(view, "form[phx-submit=replace-decision] input[type=radio][value='option:ship'][checked]")
    render_submit(view, "replace-decision", params(answered.decision_id))
    assert {:ok, current} = DecisionStore.get(answered.decision_id, ctx.store)
    assert current.revision_sequence == 1
    assert current.answer.actor.kind == :executor
    assert Decision.active_answer(current).actor == %{kind: :operator, id: "dashboard", source: :dashboard_session}
    assert Decision.active_answer(current).custom_response == "Use the replacement"
    assert has_element?(view, "h4", "Send correction")
    assert has_element?(view, "button[type=submit]", "Send correction")
    refute has_element?(view, "button[phx-click=begin-replace-decision]")
  end

  test "replacement validation errors stay visible over the recorded-answer notice", ctx do
    answered = answer(ctx, :executor)
    {:ok, view, _} = live(build_conn(), "/commands/#{answered.decision_id}")
    view |> element("button[phx-click=begin-replace-decision]") |> render_click()
    blank = %{"decision_id" => answered.decision_id, "answer" => %{"choice" => "custom", "custom_response" => "  "}}
    html = render_submit(view, "replace-decision", blank)
    assert html =~ "Enter a custom response before recording this answer."
    assert {:ok, %{revision_sequence: 0}} = DecisionStore.get(answered.decision_id, ctx.store)
  end

  test "operator answers and observe-only dashboards have no Replace control", ctx do
    answered = answer(ctx, :operator)
    {:ok, view, _} = live(build_conn(), "/commands/#{answered.decision_id}")
    refute has_element?(view, "button[phx-click=begin-replace-decision]")
    executor_decision = request_dashboard_decision(ctx.store, "read-only-executor", "reversible", decision_authority: :supervisor_allowed)
    executor_answer = answer(%{ctx | decision: executor_decision}, :executor)
    disable_dashboard_writes()
    {:ok, view, _} = live(build_conn(), "/commands/#{executor_answer.decision_id}")
    refute has_element?(view, "button[phx-click=begin-replace-decision]")
    render_click(view, "begin-replace-decision", %{"decision-id" => executor_answer.decision_id})
    refute has_element?(view, "form[phx-submit=replace-decision]")
    assert {:ok, %{revision_sequence: 0}} = DecisionStore.get(answered.decision_id, ctx.store)
  end

  test "losing an answer race shows the canonical winner and time", ctx do
    {:ok, view, _} = live(build_conn(), "/commands/#{ctx.decision.decision_id}")
    answered = answer(ctx, :executor)
    html = render_submit(view, "answer-decision", params(answered.decision_id))
    assert html =~ "Already answered by the Executor"
    assert html =~ DateTime.to_iso8601(answered.answer.accepted_at)
    assert html =~ "Original Executor direction"
    assert {:ok, current} = DecisionStore.get(answered.decision_id, ctx.store)
    assert current.answer.actor.kind == :executor
    assert current.answer.custom_response == "Original Executor direction"
    assert current.answer.accepted_at == answered.answer.accepted_at
  end

  test "delivery racing replacement disables the form and links to the unit chat", ctx do
    answered = answer(ctx, :executor)
    {:ok, view, _} = live(build_conn(), "/commands/#{answered.decision_id}")
    view |> element("button[phx-click=begin-replace-decision]") |> render_click()

    item = %{
      id: 1,
      category: :operator_message,
      target_issue_identifier: answered.ticket.identifier,
      action_id: answered.answer.action_id,
      status: :pending,
      correlation: %{decision_id: answered.decision_id, action_id: answered.answer.action_id, decision_version: answered.answer.decision_version, attempt_id: "attempt-delivery"}
    }

    assert {:ok, :accepted} = DecisionStore.record_delivery(item, ctx.store)
    html = render_submit(view, "replace-decision", params(answered.decision_id))
    assert {:ok, delivered} = DecisionStore.get(answered.decision_id, ctx.store)
    [attempt] = delivered.dispatch_attempts
    assert html =~ "Already delivered at #{DateTime.to_iso8601(attempt.delivered_at)}"
    assert has_element?(view, ".decision-answer-summary", "Original Executor direction")
    assert has_element?(view, "form fieldset[disabled]")
    assert has_element?(view, "a[href='/chat/owner/repo/987']", "Send a follow-up message")
    refute has_element?(view, "button[phx-click=begin-replace-decision]")
    assert {:ok, current} = DecisionStore.get(answered.decision_id, ctx.store)
    assert current.revision_sequence == 0
  end

  test "in-flight Executor answers cannot be replaced", ctx do
    answered = answer(ctx, :executor)

    item = %{
      id: 1,
      category: :operator_message,
      target_issue_identifier: answered.ticket.identifier,
      action_id: answered.answer.action_id,
      status: :pending,
      correlation: %{decision_id: answered.decision_id, action_id: answered.answer.action_id, decision_version: answered.answer.decision_version, attempt_id: "in-flight"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, ctx.store)
    {:ok, view, html} = live(build_conn(), "/commands/#{answered.decision_id}")
    assert html =~ "Delivery is in progress."
    refute html =~ "Already delivered at"
    assert has_element?(view, "form fieldset[disabled]")
    refute has_element?(view, "button[phx-click=begin-replace-decision]")
  end

  test "a stale replacement socket receives too_late from the store", ctx do
    answered = answer(ctx, :executor)
    [row] = AiurWeb.OperatorControlCenter.DecisionPresenter.present(answered)
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, selected_decision: row, selected_decision_id: row.decision_id, decision_actions: %{}}}
    socket = AiurWeb.OperatorControlCenter.DecisionCommands.begin_replace(socket, row.decision_id)

    item = %{
      id: 1,
      category: :operator_message,
      target_issue_identifier: answered.ticket.identifier,
      action_id: answered.answer.action_id,
      status: :pending,
      correlation: %{decision_id: answered.decision_id, action_id: answered.answer.action_id, decision_version: answered.answer.decision_version, attempt_id: "late-socket"}
    }

    assert {:ok, :accepted} = DecisionStore.record_delivery(item, ctx.store)

    reload = fn socket ->
      {:ok, delivered} = DecisionStore.get(answered.decision_id, ctx.store)
      [current] = AiurWeb.OperatorControlCenter.DecisionPresenter.present(delivered)
      Phoenix.Component.assign(socket, :selected_decision, current)
    end

    result = AiurWeb.OperatorControlCenter.DecisionEvents.handle("replace-decision", params(answered.decision_id), socket, reload)
    assert %{status: :too_late, reason: :answer_delivered, delivered_at: %DateTime{}} = result.assigns.decision_actions[row.decision_id].outcome
    assert {:ok, %{revision_sequence: 0}} = DecisionStore.get(answered.decision_id, ctx.store)
  end

  defp answer(ctx, kind) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.answer(
               ctx.decision.decision_id,
               %{idempotency_key: "original", expected_version: 1, custom_response: "Original Executor direction"},
               [actor: %{kind: kind, id: "first"}],
               ctx.store
             )

    decision
  end

  defp params(id), do: %{"decision_id" => id, "answer" => %{"choice" => "custom", "custom_response" => "Use the replacement"}}
end
