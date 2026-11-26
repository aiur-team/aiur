defmodule AiurWeb.OperatorControlCenter.DecisionCardTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures
  alias AiurWeb.OperatorControlCenter.{DecisionCard, DecisionInbox}

  @question "Keep the board or retire it?"

  defp card(decision) do
    render_component(&DecisionCard.decision_card/1, decision: decision, now: DateTime.utc_now(), writable: true)
    |> Floki.parse_fragment!()
  end

  # Visible text only: a <details> body counts, aria references do not.
  defp occurrences(doc, text), do: doc |> Floki.text(sep: "\n") |> String.split(text) |> length() |> Kernel.-(1)

  test "a legacy-option card shows the question once, two pills, and only radio-card options" do
    options = for id <- ["keep", "retire", "split"], do: %{id: id, label: "Option #{id}", description: nil, risk: nil}
    doc = card(inbox_decision("legacy", question: @question, blocking: true, options: options, recommendation: %{option_id: "retire", reason: "Unused"}))

    assert occurrences(doc, @question) == 1
    # Status pills only: the Recommended marker inside an option card is part of that option.
    pills = doc |> Floki.filter_out(".decision-more") |> Floki.filter_out(".decision-choice") |> Floki.find(".chip")
    assert length(pills) <= 2
    assert doc |> Floki.find(".decision-card-head .chip") |> Enum.map(&String.trim(Floki.text(&1))) |> hd() == "Blocking"
    assert Floki.find(doc, ".decision-option-preview") == []
    assert doc |> Floki.find(".decision-choice input[type=radio]") |> length() == 4
    assert doc |> Floki.find(".decision-more .decision-recommendation") |> Floki.text() =~ "Unused"
  end

  test "a native single-question card labels the group by the heading instead of repeating it" do
    questions = [%{question_id: "q1", question: @question, allow_other: false, options: [%{id: "a", label: "Keep"}, %{id: "b", label: "Retire"}]}]
    doc = card(inbox_decision("native", question: @question, questions: questions))

    assert occurrences(doc, @question) == 1
    [heading_id] = doc |> Floki.find(".decision-card-head h3") |> Floki.attribute("id")
    assert doc |> Floki.find("fieldset[data-question-group]") |> Floki.attribute("aria-labelledby") == [heading_id]
  end

  test "the filter bar has at most five filters and no duplicate labels" do
    html = render_component(&DecisionInbox.decision_inbox/1, decisions: [], now: DateTime.utc_now(), writable: false, retained_counts: %{})
    labels = html |> Floki.parse_fragment!() |> Floki.find(".filter-row .filter-chip") |> Floki.attribute("data-count-label")

    assert labels == Enum.uniq(labels)
    assert length(labels) in 1..5
    assert html |> Floki.parse_fragment!() |> Floki.find(".filter-row a") == []
  end
end
