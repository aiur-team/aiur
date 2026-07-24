defmodule Aiur.DecisionExpiryTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionExpiry, DecisionValidation}

  @ticket %{identifier: "979", title: "Expiry", url: nil}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @now ~U[2026-07-24 12:10:00Z]

  test "expires only old open Decisions whose ticket is no longer active" do
    test_pid = self()

    decisions = [
      decision("live", "LIVE-1", DateTime.add(@now, -600, :second)),
      decision("orphan", "DONE-1", DateTime.add(@now, -600, :second)),
      decision("young", "DONE-2", DateTime.add(@now, -299, :second)),
      decision("answered", "DONE-3", DateTime.add(@now, -600, :second), :decided)
    ]

    assert {:ok, 1} =
             DecisionExpiry.sweep(
               now: @now,
               grace_seconds: 300,
               active_identifiers_fun: fn -> {:ok, ["LIVE-1"]} end,
               decisions_fun: fn -> {:ok, decisions} end,
               expire_fun: fn decision_id, reason_class, occurred_at ->
                 send(test_pid, {:expired, decision_id, reason_class, occurred_at})
                 {:ok, %{status: :accepted}}
               end
             )

    assert_receive {:expired, orphan_id, "agent_not_running", @now}
    assert orphan_id == Enum.at(decisions, 1).decision_id
    refute_receive {:expired, _decision_id, _reason, _occurred_at}
  end

  test "fails closed when the orchestrator live set is unavailable" do
    test_pid = self()

    assert {:error, :orchestrator_unavailable} =
             DecisionExpiry.sweep(
               active_identifiers_fun: fn -> {:error, :orchestrator_unavailable} end,
               decisions_fun: fn -> flunk("must not read Decisions without a trustworthy live set") end,
               expire_fun: fn _decision_id, _reason_class, _occurred_at ->
                 send(test_pid, :expired)
                 {:ok, %{status: :accepted}}
               end
             )

    refute_receive :expired
  end

  defp decision(source_id, ticket_identifier, created_at, status \\ :open) do
    assert {:ok, decision} =
             DecisionValidation.normalize(
               %{"question" => "Still actionable?", "blocking" => true, "source_id" => source_id},
               ticket: %{@ticket | identifier: ticket_identifier},
               source: @source,
               now: created_at
             )

    %{decision | decision_status: status}
  end
end
