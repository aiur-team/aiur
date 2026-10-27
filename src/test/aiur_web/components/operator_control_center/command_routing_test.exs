defmodule AiurWeb.OperatorControlCenter.CommandRoutingTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{CommandRouting, DecisionPath, Overview, UnitsTable}
  import AiurWeb.OperatorControlCenter.UnitsTableFixtures

  test "missing routing always renders unknown, including attributed Commands" do
    for decision <- [%{}, %{route_state: nil, requester: %{"kind" => "executor"}}] do
      html = render_component(&CommandRouting.routing/1, decision: decision, now: DateTime.utc_now())
      assert html =~ "Routing…"
      refute html =~ "With Executor"
      refute html =~ "From Executor"
    end
  end

  test "Executor request chip is distinct from responder routing" do
    html = render_component(&CommandRouting.routing/1, decision: %{route_state: :with_human, requester: %{"kind" => "executor"}}, now: DateTime.utc_now())
    assert html =~ "From Executor"
  end

  test "banner uses needs-you counts rather than all open Commands" do
    html = render_component(&Overview.decisions_banner/1, retained_counts: %{open: 5, awaiting: 5, needs_you: 2, needs_you_blocking: 1})
    assert html =~ "2 Commands need you"
    refute html =~ "5 Commands"
    assert html =~ "route=needs_you"
    empty = render_component(&Overview.decisions_banner/1, retained_counts: %{open: 3, needs_you: 0, needs_you_blocking: 0})
    refute empty =~ "id=\"decisions-banner\""
  end

  test "unavailable banner never claims zero needs you" do
    html = render_component(&Overview.decisions_banner/1, retained_counts: %{open: 5, needs_you: nil, health: %{status: :unavailable}})
    assert html =~ "Command counts unavailable"
    refute html =~ "0 Commands"
  end

  test "Units Commands column reads canonical per-ticket needs-you counts and preserves unknown" do
    base_view = view([row()])
    html = render_component(&UnitsTable.units_table/1, view: Map.put(base_view, :command_counts, %{needs_you_by_ticket: %{"1110" => 2}}), now: DateTime.utc_now())
    doc = Floki.parse_fragment!(html)
    assert doc |> Floki.find("td[data-label=Commands]") |> Floki.text() |> String.trim() == "2"
    assert html =~ "route=needs_you"
    assert html =~ "ticket=1110"
    unknown = render_component(&UnitsTable.units_table/1, view: base_view, now: DateTime.utc_now()) |> Floki.parse_fragment!()
    assert unknown |> Floki.find("td[data-label=Commands]") |> Floki.text() |> String.trim() == "—"
  end

  test "routing links preserve ticket and detail context" do
    assert DecisionPath.inbox(:needs_you, %{ticket: "6411"}) == "/commands?route=needs_you&ticket=6411"
    assert DecisionPath.detail("dec-1", :with_executor) == "/commands/dec-1?route=with_executor"
  end
end
