defmodule AiurWeb.HandoffBadgeTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Presenter.Entries

  test "the adopted identity reaches the public presenter" do
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
    normal = Entries.running_entry_payload(Map.delete(entry, :adopted_from))
    assert normal.adopted_from == nil
  end
end
