defmodule AiurWeb.DashboardLive.CommandRevisionLegacyFollowUpTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionStore

  @endpoint AiurWeb.Endpoint

  test "future regression guard: legacy revision follow-up remains visible and handleable" do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    decision_store_name = Module.concat(__MODULE__, :Store)

    dispatcher = fn dispatched, _opts ->
      if dispatched.revision_sequence > 0,
        do: {:no_longer_applicable, :missing},
        else: {:ok, %{status: :accepted, item: %{id: 504}}}
    end

    store =
      start_decision_store(decision_store_name, dispatcher,
        revision_follow_up_projector: fn _decision, _action_id -> :ok end,
        revision_follow_up_resolver: fn _decision, _action_id -> :ok end
      )

    decision = request_dashboard_decision(store, "dashboard-legacy-follow-up")
    start_counting_orchestrator(orchestrator_name)

    assert {:ok, %{action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{expected_version: decision.version, idempotency_key: "original", option_id: "ship"},
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    assert {:ok, _revision} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 expected_version: decision.version,
                 expected_action_id: original.action_id,
                 expected_revision_sequence: 0,
                 idempotency_key: "legacy-correction",
                 custom_response: "Stop the inactive rollout",
                 rationale: "The target is no longer active"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 100, decision_store: decision_store_name, dashboard_writable: true)
    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert eventually(fn -> render(view) =~ "Executor follow-up required" end, 100)
    assert {:ok, pending} = DecisionStore.get(decision.decision_id, store)
    {action_id, follow_up} = Enum.find(pending.revision_follow_ups, fn {_action_id, item} -> is_nil(item.handled_at) end)
    refute follow_up.question =~ ~r/rolled back|reverted|undone/i

    html =
      render_submit(view, "handle-revision-follow-up", %{
        "decision_id" => decision.decision_id,
        "action_id" => action_id,
        "follow_up" => %{"detail" => "Opened an incident command and notified the operator"}
      })

    assert html =~ "Revision follow-up handled"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             not is_nil(current.revision_follow_ups[action_id].handled_at)
           end)

    assert {:ok, handled} = DecisionStore.get(decision.decision_id, store)
    assert handled.revision_follow_ups[action_id].handled_detail == "Opened an incident command and notified the operator"
    assert handled.revision_follow_ups[action_id].handled_by.kind == :operator
  end
end
