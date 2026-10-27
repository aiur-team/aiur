defmodule AiurWeb.OperatorControlCenter.DecisionQuestionsFormTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures
  alias Aiur.Commands.Projection
  alias Aiur.{DecisionEvent, DecisionValidation}
  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionDetail, DecisionPresenter, DecisionQuestionsForm}

  test "recommended option leads both single-question choices and detail options without hiding extra choices" do
    options = for id <- ["a", "b", "c", "d"], do: %{id: id, label: id, description: nil, risk: nil}
    decision = inbox_decision("ordering", options: options, recommendation: %{option_id: "c", reason: "Safest"})
    action = render_component(&DecisionAction.decision_action/1, decision: decision, writable: true)
    detail = render_component(&DecisionDetail.decision_detail/1, decision: decision, writable: true)
    assert Floki.parse_fragment!(action) |> Floki.find("input[type=radio]") |> Floki.attribute("value") == ["option:c", "option:a", "option:b", "option:d", "custom"]
    assert Floki.parse_fragment!(detail) |> Floki.find(".option-card .option-key") |> Enum.map(&Floki.text/1) == ["c", "a", "b", "d"]
    assert Floki.parse_fragment!(action) |> Floki.find("label.recommended .chip") |> Floki.text() == "Recommended"
  end

  test "replayed legacy attribution retains the single-answer controls" do
    {:ok, decision} = DecisionValidation.normalize(%{question: "Legacy choice?", blocking: false, options: [%{id: "yes", label: "Yes"}]}, ticket: %{identifier: "6412"})
    {:ok, event} = DecisionEvent.new(:request_attributed, decision.decision_id, decision.version, %{questions: [%{"id" => "old-metadata"}]}, event_id: "legacy-attrs", run_id: "legacy")
    {:ok, attributed} = Projection.apply(decision, event)
    [row] = DecisionPresenter.present(attributed)
    html = render_component(&DecisionAction.decision_action/1, decision: row, writable: true)
    assert html =~ ~s(name="answer[choice]")
    assert html =~ ~s(value="option:yes")
    refute html =~ "data-question-group"
    answered = %{row | answer: Map.put(action_answer(:operator), :selected_option_id, "yes")}
    summary = render_component(&DecisionAction.decision_action/1, decision: answered, writable: false)
    assert Floki.parse_fragment!(summary) |> Floki.find(".decision-answer-summary strong") |> Floki.text() == "Yes"
  end

  test "an undecodable native answer displays unavailable instead of raw stored data" do
    questions = [%{question_id: "q", question: "Where?", allow_other: false, options: [%{id: "a", label: "Alpha"}, %{id: "b", label: "Beta"}]}]
    response = Jason.encode!(%{kind: "question_answers", question_answers: %{q: ["Missing"]}})
    answer = Map.merge(action_answer(:operator), %{selected_option_id: nil, custom_response: response})
    decision = inbox_decision("unknown-answer", questions: questions, answer: answer)
    html = render_component(&DecisionAction.decision_action/1, decision: decision, writable: false)
    assert Floki.parse_fragment!(html) |> Floki.find(".decision-answer-summary strong") |> Floki.text() == "Answer unavailable"
    refute html =~ "Missing"
  end

  test "invalid selections and disallowed Other cannot become complete answers" do
    question = %{"question_id" => "q", "question" => "Where?", "multi_select" => false, "allow_other" => false, "options" => [%{"id" => "a", "label" => "Alpha"}]}

    for choice <- [[], ["option:missing"], ["other"], ["option:a", "option:a"]] do
      assert {:error, "Answer every question." <> _rest} = DecisionQuestionsForm.answer_content([question], %{"question_choices" => %{"q" => choice}})
    end
  end
end
