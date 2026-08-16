defmodule Aiur.DecisionExpiryTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionExpiry, DecisionValidation}

  @ticket %{identifier: "979", title: "Expiry", url: nil}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @now ~U[2026-07-24 12:10:00Z]
  @async_assert_timeout 1_000

  test "expires only old open Decisions whose ticket is no longer active" do
    test_pid = self()

    decisions = [
      decision("live", "LIVE-1", DateTime.add(@now, -600, :second)),
      decision("orphan", "DONE-1", DateTime.add(@now, -600, :second), blocking: false),
      decision("young", "DONE-2", DateTime.add(@now, -299, :second), blocking: false),
      decision("answered", "DONE-3", DateTime.add(@now, -600, :second), status: :decided, blocking: false)
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

    assert_received {:expired, orphan_id, "agent_not_running", @now}
    assert orphan_id == Enum.at(decisions, 1).decision_id
    refute_received {:expired, _decision_id, _reason, _occurred_at}
  end

  test "does not expire a blocking human-required Decision whose agent is idle waiting on it" do
    test_pid = self()

    decisions = [
      decision("blocked", "DONE-1", DateTime.add(@now, -600, :second))
    ]

    assert {:ok, 0} =
             DecisionExpiry.sweep(
               now: @now,
               grace_seconds: 300,
               active_identifiers_fun: fn -> {:ok, []} end,
               decisions_fun: fn -> {:ok, decisions} end,
               expire_fun: fn decision_id, reason_class, occurred_at ->
                 send(test_pid, {:expired, decision_id, reason_class, occurred_at})
                 {:ok, %{status: :accepted}}
               end
             )

    refute_received {:expired, _decision_id, _reason, _occurred_at}
  end

  test "still expires a blocking supervisor-answerable Decision whose ticket is no longer active" do
    test_pid = self()

    decisions = [
      decision("supervised", "DONE-1", DateTime.add(@now, -600, :second), authority: "supervisor_allowed")
    ]

    assert {:ok, 1} =
             DecisionExpiry.sweep(
               now: @now,
               grace_seconds: 300,
               active_identifiers_fun: fn -> {:ok, []} end,
               decisions_fun: fn -> {:ok, decisions} end,
               expire_fun: fn decision_id, reason_class, occurred_at ->
                 send(test_pid, {:expired, decision_id, reason_class, occurred_at})
                 {:ok, %{status: :accepted}}
               end
             )

    assert_received {:expired, _decision_id, "agent_not_running", @now}
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

    refute_received :expired
  end

  test "scheduled sweeps use the supplied sources" do
    test_pid = self()

    {:ok, pid} =
      DecisionExpiry.start_link(
        name: nil,
        initial_delay_ms: 0,
        interval_ms: 60_000,
        active_identifiers_fun: fn ->
          send(test_pid, :sweep_started)

          receive do
            :continue_sweep -> {:ok, []}
          end
        end,
        decisions_fun: fn ->
          {:ok, [decision("orphan", "DONE-1", DateTime.add(@now, -600, :second), blocking: false)]}
        end,
        expire_fun: fn decision_id, reason_class, occurred_at ->
          send(test_pid, {:expired, decision_id, reason_class, occurred_at})
          {:ok, %{status: :accepted}}
        end,
        now: @now,
        grace_seconds: 300
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive :sweep_started, @async_assert_timeout
    send(pid, :continue_sweep)
    :sys.get_state(pid)
    assert_received {:expired, _decision_id, "agent_not_running", @now}
  end

  defp decision(source_id, ticket_identifier, created_at, overrides \\ []) do
    status = Keyword.get(overrides, :status, :open)
    blocking = Keyword.get(overrides, :blocking, true)
    authority = Keyword.get(overrides, :authority, "human_required")

    assert {:ok, decision} =
             DecisionValidation.normalize(
               %{
                 "question" => "Still actionable?",
                 "blocking" => blocking,
                 "authority" => authority,
                 "source_id" => source_id
               },
               ticket: %{@ticket | identifier: ticket_identifier},
               source: @source,
               now: created_at
             )

    %{decision | decision_status: status}
  end
end
