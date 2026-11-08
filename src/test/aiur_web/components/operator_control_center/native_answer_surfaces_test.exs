defmodule AiurWeb.OperatorControlCenter.NativeAnswerSurfacesTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures
  alias AiurWeb.OperatorControlCenter.DecisionRevisionAction

  test "History decodes every native question and selection" do
    document = native_decision(valid_values()) |> List.wrap() |> render_history() |> Floki.parse_fragment!()
    assert document |> Floki.find(".history-decision") |> Floki.text() == "“Rollout?: Safe rollout\nTargets?: Alpha, Beta”"
  end

  test "History reports an invalid native answer as unavailable" do
    document = native_decision(invalid_values()) |> List.wrap() |> render_history() |> Floki.parse_fragment!()
    assert document |> Floki.find(".history-decision") |> Floki.text() == "Answer unavailable"
  end

  test "Send correction decodes original and revision native answers" do
    document = revised_decision(valid_values()) |> correction_document()
    assert document |> Floki.find(".decision-revision-entry.original strong") |> Floki.text() == "Rollout?: Safe rollout\nTargets?: Alpha"
    assert document |> Floki.find(".decision-revision-entry:not(.original) strong") |> Floki.text() == "Rollout?: Safe rollout\nTargets?: Alpha, Beta"
  end

  test "Send correction reports invalid original and revision answers as unavailable" do
    decision = revised_decision(invalid_values())
    document = %{decision | original_answer: decision.answer} |> correction_document()
    assert document |> Floki.find(".decision-revision-entry strong") |> Enum.map(&Floki.text/1) == ["Answer unavailable", "Answer unavailable"]
  end

  defp correction_document(decision) do
    render_component(&DecisionRevisionAction.decision_revision_action/1, decision: decision, writable: false) |> Floki.parse_fragment!()
  end

  defp valid_values, do: %{"q1" => ["Safe rollout"], "q2" => ["Alpha", "Beta"]}
  defp invalid_values, do: %{"q1" => ["Unknown"], "q2" => ["Alpha"]}

  defp revised_decision(values) do
    decision = native_decision(values)
    original = native_decision(%{"q1" => ["Safe rollout"], "q2" => ["Alpha"]}).answer
    Map.merge(decision, %{original_answer: original, revision_sequence: 1, revisions: [%{sequence: 1, answer: decision.answer, reason: "Updated targets", result: :dispatched}]})
  end

  defp native_decision(values) do
    questions = [
      %{question_id: "q1", question: "Rollout?", allow_other: false, options: [%{id: "safe", label: "Safe rollout"}, %{id: "hold", label: "Hold"}]},
      %{question_id: "q2", question: "Targets?", multi_select: true, allow_other: false, options: [%{id: "a", label: "Alpha"}, %{id: "b", label: "Beta"}]}
    ]

    response = Jason.encode!(%{kind: "question_answers", question_answers: values})
    answer = action_answer(:operator, selected_option_id: nil, custom_response: response)
    inbox_decision("native-history", questions: questions, decision_status: :decided, answer: answer)
  end
end
