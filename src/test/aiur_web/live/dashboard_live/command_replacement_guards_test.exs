defmodule AiurWeb.DashboardLive.CommandReplacementGuardsTest do
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
      request_dashboard_decision(store, "replacement-guards", "reversible",
        decision_authority: :supervisor_allowed,
        ticket: %{identifier: "987", title: "Replace", url: "https://github.com/owner/repo/issues/987"}
      )

    %{store: store, decision: decision}
  end

  test "a writable dashboard rejects forged replacement events for an operator answer", ctx do
    answered = answer(ctx, :operator)
    {:ok, view, _} = live(build_conn(), "/commands/#{answered.decision_id}")

    render_click(view, "begin-replace-decision", %{"decision-id" => answered.decision_id})
    refute has_element?(view, "form[phx-submit=replace-decision]")

    render_submit(view, "replace-decision", params(answered.decision_id))
    refute has_element?(view, "form[phx-submit=replace-decision]")
    assert_original_answer(ctx.store, answered)
  end

  test "replacement submission without beginning replacement preserves the Executor answer", ctx do
    answered = answer(ctx, :executor)
    {:ok, view, _} = live(build_conn(), "/commands/#{answered.decision_id}")
    assert has_element?(view, "button[phx-click=begin-replace-decision]")

    render_submit(view, "replace-decision", params(answered.decision_id))
    refute has_element?(view, "form[phx-submit=replace-decision]")
    assert_original_answer(ctx.store, answered)
  end

  defp answer(ctx, kind) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.answer(
               ctx.decision.decision_id,
               %{idempotency_key: "original", expected_version: 1, custom_response: "Original direction"},
               [actor: %{kind: kind, id: "first"}],
               ctx.store
             )

    decision
  end

  defp assert_original_answer(store, answered) do
    assert {:ok, current} = DecisionStore.get(answered.decision_id, store)
    assert current.revision_sequence == 0
    assert Decision.active_answer(current) == answered.answer
    assert current.answer.custom_response == "Original direction"
  end

  defp params(id), do: %{"decision_id" => id, "answer" => %{"choice" => "custom", "custom_response" => "Forged replacement"}}
end
