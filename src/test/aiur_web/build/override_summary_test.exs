defmodule AiurWeb.Build.OverrideSummaryTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AiurWeb.Build.OverrideSummary
  alias AiurWeb.OperatorControlCenter.DecisionCommands

  test "fleet badges include delivered and queued overrides but omit implemented and superseded work" do
    decisions = Enum.map([:queued, :delivered, :implemented, :superseded], &decision/1)
    rows = DecisionCommands.pending_override_rows(decisions)
    assert Enum.map(rows, & &1.label) == ["Delivered", "Queued — waiting for a slot"]
    html = render_component(&OverrideSummary.summary/1, state: {:ok, rows})
    dom = Floki.parse_fragment!(html)
    assert dom |> Floki.find("details > summary") |> Floki.text() =~ "Overrides: 2"
    assert Floki.find(dom, "details[open]") == []
    links = html |> Floki.parse_fragment!() |> Floki.find(".fleet-override-badge")
    assert length(links) == 2
    assert Floki.attribute(links, "href") == ["/commands/cmd-delivered", "/commands/cmd-queued"]
    assert Floki.text(links) =~ "Ticket #42"
  end

  test "unavailable store is shown explicitly instead of an empty fleet summary" do
    assert DecisionCommands.pending_overrides(store: :missing_override_summary_store) == :unavailable
    html = render_component(&OverrideSummary.summary/1, state: :unavailable)
    assert html =~ "Override status unavailable"
    dom = Floki.parse_fragment!(html)
    assert dom |> Floki.find("summary") |> Floki.text() =~ "Overrides: ?"
    assert Floki.attribute(Floki.find(dom, "summary"), "title") == ["Override status unavailable"]
    assert Floki.find(dom, "details[open]") == []
    refute html =~ "fleet-override-badge"
  end

  defp decision(state) do
    ticket = %{identifier: "42", url: "https://github.com/o/r/issues/42"}
    record = %{state: state, route: :capacity_wait, action_id: "override", ticket: ticket}
    struct(Aiur.Decision, %{decision_id: "cmd-#{state}", ticket: ticket, active_action_id: "override", overrides: [record]})
  end
end
