defmodule AiurWeb.OperatorControlCenter.DecisionReplacementTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AiurWeb.OperatorControlCenter.{DecisionOutcomes, DecisionReplacement}

  test "accepted and duplicate notices advance to successful delivery instead of a late-answer error" do
    at = DateTime.utc_now()
    decision = delivered_decision(at)

    for status <- [:accepted, :duplicate], delivery <- [:pending, :delivered] do
      outcome = %{status: status, delivery: delivery, decision: %{decision | dispatch_attempts: []}}
      html = render_notice(decision, %{outcome: outcome, notice: "Answer recorded. Delivering to #987…"})
      document = Floki.parse_fragment!(html)
      assert document |> Floki.find("p[role=status]") |> Floki.text() == "Delivered to #987 at #{DateTime.to_iso8601(DateTime.truncate(at, :second))}"
      assert Floki.find(document, "p[role=alert]") == []
      assert DecisionOutcomes.disabled?(decision, %{outcome: outcome})
      refute html =~ "Replace</button>"
    end
  end

  test "a delivered competing answer still identifies its winner and accepted time" do
    accepted_at = DateTime.add(DateTime.utc_now(), -10, :second)
    decision = delivered_decision(DateTime.utc_now())
    winner = %{actor_kind: :executor, accepted_at: accepted_at, summary: "Keep the original release"}
    html = render_notice(decision, %{outcome: %{status: :already_answered, winner: winner}})
    document = Floki.parse_fragment!(html)
    assert document |> Floki.find("p[role=alert]") |> Floki.text() == "Already answered by the Executor at #{DateTime.to_iso8601(DateTime.truncate(accepted_at, :second))}: 'Keep the original release'"
    assert DecisionOutcomes.disabled?(decision, %{})
  end

  test "an in-flight rejection advances to the confirmed delivery time" do
    at = DateTime.utc_now()
    decision = delivered_decision(at)
    html = render_notice(decision, %{outcome: %{status: :too_late, reason: :answer_in_flight}})
    document = Floki.parse_fragment!(html)
    assert document |> Floki.find("p[role=alert]") |> Floki.text() == "Already delivered at #{DateTime.to_iso8601(DateTime.truncate(at, :second))}. Send a follow-up message instead."
    assert document |> Floki.find("a[href='/chat/owner/repo/987']") |> Floki.text() == "Send a follow-up message"
    refute html =~ "Delivery is in progress"
  end

  defp render_notice(decision, state),
    do: render_component(&DecisionReplacement.decision_replacement/1, decision: decision, state: state, writable: true, live_connected: true)

  defp delivered_decision(at) do
    %{
      decision_id: "delivered-command",
      decision_status: :decided,
      ticket: %{identifier: "987", url: "https://github.com/owner/repo/issues/987"},
      conflict_summary: %{actor_kind: :executor, delivered?: true, replaceable: false},
      dispatch_attempts: [%{delivered_at: at}],
      acknowledgement: nil
    }
  end
end
