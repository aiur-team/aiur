defmodule AiurWeb.OperatorControlCenter.DecisionTimelineTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AiurWeb.OperatorControlCenter.DecisionTimeline

  test "durable routing facts retain order, causes, absolute times and ages" do
    now = DateTime.utc_now()

    entries =
      for {type, offset} <- [{:routed, -120}, {:escalated, -90}, {:human_needed, -60}] do
        %{type: type, at: DateTime.add(now, offset), cause: if(type == :routed, do: nil, else: :executor_answer_timeout)}
      end

    html = render_component(&DecisionTimeline.decision_timeline/1, audit_history: entries, now: now)
    doc = Floki.parse_fragment!(html)
    assert Floki.find(doc, "li strong") |> Enum.map(&Floki.text/1) == ["Routed", "Escalated", "Human needed"]
    assert Floki.attribute(doc, "time", "datetime") == Enum.map(entries, &DateTime.to_iso8601(DateTime.truncate(&1.at, :second)))
    assert html =~ "Executor answer timed out"
    assert html =~ "2m ago"
    assert html =~ "1m ago"
  end

  test "unknown facts remain visible as neutral Updated entries" do
    html = render_component(&DecisionTimeline.decision_timeline/1, audit_history: [%{type: "future_fact", at: DateTime.utc_now(), cause: :future_cause}])
    assert Floki.parse_fragment!(html) |> Floki.find("li strong") |> Floki.text() == "Updated"
    assert html =~ "Unknown cause"
  end

  test "unavailable history differs from an empty successful history" do
    html = render_component(&DecisionTimeline.decision_timeline/1, audit_history: :unavailable)
    assert Floki.parse_fragment!(html) |> Floki.find("[role=status]") |> Floki.text() == "Timeline unavailable. Recorded events could not be loaded."
    refute html =~ "No durable Command events"
    empty = render_component(&DecisionTimeline.decision_timeline/1, audit_history: [])
    assert empty =~ "No durable Command events were recorded."
    refute empty =~ "Timeline unavailable"
  end
end
