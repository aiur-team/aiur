defmodule AiurWeb.DashboardLive.CommandQuestionsTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes
  alias Aiur.{Commands, DecisionStore}
  @endpoint AiurWeb.Endpoint

  setup do
    store_name = Module.concat(__MODULE__, Store)
    store = start_decision_store(store_name, fn _, _ -> {:error, :no_running_agent} end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end)
    orchestrator = Module.concat(__MODULE__, Orchestrator)
    start_counting_orchestrator(orchestrator)
    start_test_endpoint(orchestrator: orchestrator, decision_store: store_name, dashboard_writable: true, control_center_cache: false)

    questions = [
      %{question_id: "q1", question: "Proceed?", options: [%{id: "yes", label: "Yes"}, %{id: "no", label: "No"}], allow_other: false},
      %{question_id: "q2", question: "Targets?", options: [%{id: "a", label: "Alpha"}, %{id: "b", label: "Beta"}], multi_select: true, allow_other: true}
    ]

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{source_id: "questions", question: "Choose release targets", blocking: true, reversibility: "reversible"},
        [ticket: %{identifier: "6412", title: "Questions", url: nil}, source: %{agent_id: "agent-6412", session_id: "questions-session"}, questions: questions],
        store
      )

    %{store: store, decision: decision}
  end

  test "partial native answers are rejected before store mutation and preserve the draft", ctx do
    {:ok, view, _html} = live(build_conn(), "/commands/#{ctx.decision.decision_id}")
    form = form(ctx)
    assert view |> element(form <> " fieldset:nth-of-type(1) legend") |> render() =~ "Proceed?"
    assert view |> element(form <> " fieldset:nth-of-type(2) legend") |> render() =~ "Targets?"
    html = render_submit(view, "answer-decision", %{decision_id: ctx.decision.decision_id, answer: %{question_choices: %{q1: ["option:yes"]}}})
    assert html =~ "Answer every question."
    assert has_element?(view, form <> " input[value='option:yes'][checked]")
    assert {:ok, current} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert current.answer == nil
  end

  test "multi-select form submits every selected label through Answering", ctx do
    {:ok, view, _html} = live(build_conn(), "/commands/#{ctx.decision.decision_id}")
    form = form(ctx)
    assert has_element?(view, form <> " input[type=checkbox][name='answer[question_choices][q2][]'][value='option:a']")
    assert has_element?(view, form <> " input[type=radio][name='answer[question_choices][q1][]'][required]")
    refute has_element?(view, form <> " textarea[name='answer[custom_response]']")
    render_submit(view, "answer-decision", %{decision_id: ctx.decision.decision_id, answer: %{question_choices: %{q1: ["option:yes"], q2: ["option:a", "option:b"]}}})
    assert {:ok, current} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert Commands.Answering.decode_question_answers(current.questions, current.answer) == {:ok, %{"q1" => ["Yes"], "q2" => ["Alpha", "Beta"]}}
  end

  test "Other is a required custom response only for a question that allows it", ctx do
    {:ok, view, _html} = live(build_conn(), "/commands/#{ctx.decision.decision_id}")
    form = form(ctx)
    choices = %{q1: ["option:no"], q2: ["other"]}
    render_change(view, "decision-action-change", %{decision_id: ctx.decision.decision_id, answer: %{question_choices: choices}})
    assert has_element?(view, form <> " input[name='answer[question_other][q2]'][required]")
    refute has_element?(view, form <> " input[name='answer[question_choices][q1][]'][value=other]")
    render_submit(view, "answer-decision", %{decision_id: ctx.decision.decision_id, answer: %{question_choices: choices, question_other: %{q2: "Canary"}}})
    assert {:ok, current} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert Commands.Answering.decode_question_answers(current.questions, current.answer) == {:ok, %{"q1" => ["No"], "q2" => ["Canary"]}}
  end

  defp form(ctx), do: "#decision-detail-#{ctx.decision.decision_id} form[phx-submit=answer-decision]"
end
