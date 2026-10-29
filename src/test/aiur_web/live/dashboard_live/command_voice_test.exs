defmodule AiurWeb.DashboardLive.CommandVoiceTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionEvent
  alias Aiur.DecisionStore
  alias AiurWeb.DashboardLiveSupport.StoreStubs.RejectingDecisionStore

  @endpoint AiurWeb.Endpoint

  setup do
    start_counting_orchestrator(__MODULE__.Orchestrator)
    :ok
  end

  test "card and detail forms expose current Command voice target and available Dictate before Custom response" do
    store = start_decision_store(__MODULE__.Store, fn _, _ -> {:error, :no_running_agent} end)
    decision = request_dashboard_decision(store, "voice-form")
    endpoint(__MODULE__.Store)

    for path <- ["/commands", "/commands/#{decision.decision_id}"] do
      {:ok, view, _} = live(build_conn(), path)
      selector = "#decision-answer-form-#{decision.decision_id}"
      assert has_element?(view, "#{selector}[phx-hook=VoiceInput][data-voice-select-custom='answer[choice]']")
      assert has_element?(view, "#{selector} [data-voice-mode=dictate][aria-disabled=false]")
      refute has_element?(view, "#{selector} [data-voice-conversation]")
      refute has_element?(view, "#{selector} [data-voice-mode=converse]")
      refute has_element?(view, "#{selector} [data-voice-input]")
      target = view |> element("#{selector} [data-voice-root]") |> render() |> Floki.parse_fragment!() |> Floki.attribute("data-voice-target") |> hd() |> Jason.decode!()
      assert target == %{"kind" => "command", "decision_id" => decision.decision_id, "expected_version" => decision.version}
      assert has_element?(view, "#{selector} [data-voice-root][data-voice-surface=command_response]")

      params = %{"decision_id" => decision.decision_id, "answer" => %{"choice" => "custom", "custom_response" => "Draft"}}
      render_change(view, "decision-action-change", params)
      assert has_element?(view, "#{selector} textarea[data-voice-input][maxlength='4000']", "Draft")
      assert has_element?(view, "#{selector} button[data-voice-send][type=submit]")
    end
  end

  # The store and payload are unchanged; these are future-regression guards for
  # the existing submit path reused by voice, not coverage of new store logic.
  test "dictated text uses existing answer payload and double submission records one durable answer" do
    store = start_decision_store(__MODULE__.Store, fn _, _ -> {:error, :no_running_agent} end)
    decision = request_dashboard_decision(store, "voice-record")
    endpoint(__MODULE__.Store)
    {:ok, view, _} = live(build_conn(), "/commands/#{decision.decision_id}")
    params = %{"decision_id" => decision.decision_id, "answer" => %{"choice" => "custom", "custom_response" => "Use the safer path"}}
    render_change(view, "decision-action-change", params)
    render_submit(view, "answer-decision", params)
    render_submit(view, "answer-decision", params)
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.custom_response == "Use the safer path"
    assert current.answer.decision_version == decision.version
    assert String.starts_with?(current.answer.idempotency_key, "ui_")
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1)) == 1
  end

  # Existing conflict semantics deliberately remain unchanged by dictation.
  test "stale answer keeps dictated text in the voice field and sends the existing concurrency metadata" do
    decision = dashboard_decision("dec-voice-stale")
    start_supervised!({RejectingDecisionStore, name: __MODULE__.RejectingStore, decision: decision, report: self()})
    endpoint(__MODULE__.RejectingStore)
    {:ok, view, _} = live(build_conn(), "/commands/#{decision.decision_id}")
    params = %{"decision_id" => decision.decision_id, "answer" => %{"choice" => "custom", "custom_response" => "Keep this dictated draft"}}
    render_change(view, "decision-action-change", params)
    html = render_submit(view, "answer-decision", params)
    assert html =~ "This Command changed. Refresh to see the latest."
    assert has_element?(view, "[data-voice-delivery][data-delivery-state=failed]", "This Command changed. Refresh to see the latest.")
    assert has_element?(view, "textarea[data-voice-input]", "Keep this dictated draft")
    assert_receive {:dashboard_answer_attempt, id, payload, opts}, 1_000
    assert id == decision.decision_id
    assert payload["custom_response"] == "Keep this dictated draft"
    assert payload["expected_version"] == decision.version
    assert String.starts_with?(payload["idempotency_key"], "ui_")
    assert opts[:actor].kind == :operator
  end

  defp endpoint(store) do
    start_test_endpoint(
      orchestrator: __MODULE__.Orchestrator,
      snapshot_timeout_ms: 100,
      decision_store: store,
      control_center_cache: false,
      dashboard_writable: true,
      capabilities_report_fun: fn -> %{capabilities: %{"voice.stt" => %{state: :available}}} end
    )
  end
end
