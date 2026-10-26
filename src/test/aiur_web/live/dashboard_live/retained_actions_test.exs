defmodule AiurWeb.DashboardLive.RetainedActionsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionStore

  @endpoint AiurWeb.Endpoint

  test "a writable answer uses selected retained detail outside the overview window" do
    orchestrator_name = Module.concat(__MODULE__, :OutsideWindowAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :OutsideWindowAnswerStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_072}}}
      end)

    decision = request_dashboard_decision(store, "outside-window-answer", "reversible", now: ~U[2026-07-13 08:00:00Z])
    add_newer_dashboard_decisions(store, decision, "outside-window-answer-newer")

    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-submit="answer-decision")

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The retained detail remains authoritative"}
      })

    assert html =~ "Answer recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             not is_nil(current.answer)
           end)
  end

  test "a non-selected Command stays answerable from another Command's detail page" do
    orchestrator_name = Module.concat(__MODULE__, :NonSelectedAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :NonSelectedAnswerStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_099}}}
      end)

    selected = request_dashboard_decision(store, "non-selected-detail")
    other = request_dashboard_decision(store, "non-selected-other-open")

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    # Opening one Command's detail page must not make the other Command
    # unanswerable: its inline form is still rendered and must reach the store.
    {:ok, view, html} = live(build_conn(), "/commands/#{selected.decision_id}")
    assert html =~ ~s(phx-submit="answer-decision")

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => other.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "Answering a non-selected Command"}
      })

    # The socket pre-check must not reject the answer: the false "no longer
    # open" claim would leave the Command open in the store.
    refute html =~ "is not loaded on this page"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(other.decision_id, store)
             current.answer.selected_option_id == "ship"
           end)

    assert {:ok, answered} = DecisionStore.get(other.decision_id, store)
    assert answered.decision_status == :decided
    assert answered.answer.rationale == "Answering a non-selected Command"

    # The selected Command was left untouched by the answer to the other one.
    assert {:ok, selected_current} = DecisionStore.get(selected.decision_id, store)
    assert is_nil(selected_current.answer)
  end

  test "a writable revision uses selected retained detail outside the overview window" do
    orchestrator_name = Module.concat(__MODULE__, :OutsideWindowRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :OutsideWindowRevisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_073}}}
      end)

    decision = request_dashboard_decision(store, "outside-window-revision", "reversible", now: ~U[2026-07-13 08:00:00Z])

    assert {:ok, _accepted} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "outside-window-original", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    add_newer_dashboard_decisions(store, decision, "outside-window-revision-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ "Revise Command"

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Hold for the retained evidence",
          "reason" => "The overview window advanced"
        }
      })

    assert html =~ "Revision recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             current.revision_sequence == 1
           end)
  end

  test "an answer keeps the selected retained detail when a concurrent overview refresh omits it" do
    orchestrator_name = Module.concat(__MODULE__, :StalePayloadAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StalePayloadAnswerStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_074}}}
      end)

    decision = request_dashboard_decision(store, "stale-payload-answer", "reversible", now: ~U[2026-07-13 08:00:00Z])
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")
    add_newer_dashboard_decisions(store, decision, "stale-payload-answer-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    assert reload_view(view) =~ ~s(phx-submit="answer-decision")

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The direct selection remains current"}
      })

    assert html =~ "Answer recorded"
  end

  test "a revision keeps the selected retained detail when a concurrent overview refresh omits it" do
    orchestrator_name = Module.concat(__MODULE__, :StalePayloadRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StalePayloadRevisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_075}}}
      end)

    decision = request_dashboard_decision(store, "stale-payload-revision", "reversible", now: ~U[2026-07-13 08:00:00Z])

    assert {:ok, _accepted} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "stale-payload-original", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")
    add_newer_dashboard_decisions(store, decision, "stale-payload-revision-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    assert reload_view(view) =~ "Revise Command"

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Retain the safer correction",
          "reason" => "The overview changed while this detail stayed selected"
        }
      })

    assert html =~ "Revision recorded"
  end

  test "an answer uses the rendered retained version when the overview has an older same-ID row" do
    orchestrator_name = Module.concat(__MODULE__, :VersionedAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :VersionedAnswerStore)
    detail_store_name = Module.concat(__MODULE__, :VersionedAnswerDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_076}}}
      end)

    overview = request_dashboard_decision(store, "versioned-answer")

    detail =
      replace_dashboard_decision(store, overview,
        question: "Destroy the active release?",
        reversibility: "irreversible",
        option_label: "Destroy the active release"
      )

    start_versioned_detail_store(detail_store_name, overview, detail)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{detail.decision_id}")
    assert html =~ "Destroy the active release?"
    assert html =~ "Destroy the active release"
    refute html =~ "I understand this Command is irreversible or destructive."
    refute html =~ "Should the dashboard ship this change?"

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => detail.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "rationale" => "The current retained detail is destructive"
        }
      })

    assert html =~ "Answer recorded"

    assert_receive {:versioned_detail_answer, decision_id, payload, _opts}, 1000
    assert decision_id == detail.decision_id
    assert payload["expected_version"] == detail.version
  end

  test "a revision uses the rendered retained version when the overview has an older same-ID row" do
    orchestrator_name = Module.concat(__MODULE__, :VersionedRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :VersionedRevisionStore)
    detail_store_name = Module.concat(__MODULE__, :VersionedRevisionDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_077}}}
      end)

    overview = request_dashboard_decision(store, "versioned-revision")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               overview.decision_id,
               %{
                 "idempotency_key" => "versioned-revision-original",
                 "expected_version" => overview.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    detail =
      replace_dashboard_decision(store, overview,
        question: "Destroy the active release after review?",
        reversibility: "irreversible",
        option_label: "Destroy the reviewed release"
      )

    start_versioned_detail_store(detail_store_name, overview, detail)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{detail.decision_id}")
    assert html =~ "Destroy the active release after review?"
    assert html =~ "Destroy the reviewed release"
    assert html =~ "I understand this revised Command is irreversible or destructive."
    refute html =~ "Should the dashboard ship this change?"

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => detail.decision_id,
        "revision" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "reason" => "The retained version changes the operation"
        }
      })

    assert html =~ "Revision recorded"

    assert_receive {:versioned_detail_revision, decision_id, payload, _opts}, 1000
    assert decision_id == detail.decision_id
    assert payload["expected_version"] == detail.version
    assert payload["expected_action_id"] == detail.active_action_id
  end
end
