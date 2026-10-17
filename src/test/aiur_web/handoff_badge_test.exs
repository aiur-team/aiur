defmodule AiurWeb.HandoffBadgeTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AiurWeb.OperatorControlCenter.FleetTable
  alias AiurWeb.Presenter.Entries

  test "the adopted identity reaches the presenter and renders a fleet badge" do
    entry = %{
      issue_id: "1",
      identifier: "1",
      session_id: "kept-session",
      state: "in-progress",
      title: "Kept agent",
      adopted_from: "restart-1",
      work_state: :working,
      waiting_reason: :active,
      open_decision_count: 0,
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      started_at: ~U[2026-10-15 10:00:00Z]
    }

    row = Entries.running_entry_payload(entry)
    assert row.adopted_from == "restart-1"
    html = render_component(&FleetTable.fleet_table/1, %{fleet: %{running: [row]}, now: ~U[2026-10-15 10:00:01Z]})
    assert html =~ ~s(title="Adopted from handoff restart-1")
    assert html =~ ">adopted</span>"
    normal = Entries.running_entry_payload(Map.delete(entry, :adopted_from))
    html = render_component(&FleetTable.fleet_table/1, %{fleet: %{running: [normal]}, now: ~U[2026-10-15 10:00:01Z]})
    refute html =~ ">adopted</span>"
  end
end
