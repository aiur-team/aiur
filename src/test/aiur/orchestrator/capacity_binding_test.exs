defmodule Aiur.Orchestrator.CapacityBindingTest do
  @moduledoc """
  The classification the CLI and every dashboard share. Four fleets can report
  the identical `2 cap` and want four different operator responses, so the
  distinguishing fact is the binding constraint, not the number.
  """

  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.CapacityBinding

  @full %{
    active: 2,
    occupied: 2,
    reserved_paused: 0,
    available: 0,
    max: 2,
    effective: 2,
    configured: 2,
    session_override?: false,
    queued_demand?: true
  }

  test "a persisted admission hold is the only thing allowed to name an admission signal" do
    hold = %{signal: :load, measured: 9.5, threshold: 4.0}

    assert CapacityBinding.binding(Map.put(@full, :capacity_hold, hold)) == {:admission, hold}
    assert CapacityBinding.short_label({:admission, hold}) == "admission: load"
  end

  # A well-formed figure with no timestamp is indistinguishable from a fresh
  # one, which is how a `load=24.14` that had been current eight minutes earlier
  # read as authoritative beside a live `LOAD 6.34` line (#2527).
  describe "admission sample freshness" do
    @sampled_at ~U[2026-09-02 22:00:00Z]

    defp held(hold_overrides \\ %{}) do
      Map.put(
        @full,
        :capacity_hold,
        Map.merge(%{signal: :load, measured: 24.14, threshold: 24.0, measured_at: @sampled_at}, hold_overrides)
      )
    end

    test "a sample taken within the poll window is reported without a stale marker" do
      now = DateTime.add(@sampled_at, 30, :second)

      assert {:admission, hold} = CapacityBinding.binding(held(), %{effective_interval_ms: 30_000}, now)
      refute Map.has_key?(hold, :stale_sample?)
      assert CapacityBinding.sample_age_seconds(hold, now) == 30
      assert CapacityBinding.short_label({:admission, hold}) == "admission: load"
    end

    test "a sample older than the poll cadence allows is marked stale" do
      now = DateTime.add(@sampled_at, 8 * 60, :second)

      assert {:admission, hold} = CapacityBinding.binding(held(), %{effective_interval_ms: 30_000}, now)
      assert hold.stale_sample? == true
      assert CapacityBinding.sample_age_seconds(hold, now) == 480
      assert CapacityBinding.short_label({:admission, hold}) == "admission: load (stale sample)"
    end

    # A very wide cadence must not license an ancient figure: the bound is capped
    # at five minutes whatever the poll interval is.
    test "a widely-spaced poll cannot make an eight-minute-old sample read as fresh" do
      now = DateTime.add(@sampled_at, 8 * 60, :second)

      assert {:admission, hold} = CapacityBinding.binding(held(), %{effective_interval_ms: 600_000}, now)
      assert hold.stale_sample? == true
    end

    # The stamp survives a JSON round trip through the status snapshot.
    test "an ISO-8601 stamp is read the same as a DateTime" do
      hold = held(%{measured_at: DateTime.to_iso8601(@sampled_at)})
      now = DateTime.add(@sampled_at, 8 * 60, :second)

      assert {:admission, %{stale_sample?: true}} = CapacityBinding.binding(hold, %{}, now)
      assert CapacityBinding.sample_age_seconds(hold.capacity_hold, now) == 480
    end

    # An unstamped hold predates #2527. Judging it fresh would restate the bug;
    # judging it stale would flag a hold nobody can date.
    test "a hold with no stamp is neither aged nor called stale" do
      hold = %{signal: :load, measured: 24.14, threshold: 24.0}

      assert CapacityBinding.binding(Map.put(@full, :capacity_hold, hold)) == {:admission, hold}
      assert CapacityBinding.sample_age_seconds(hold) == nil
      refute CapacityBinding.stale_sample?(hold)
    end
  end

  test "an AIMD backoff below the session ceiling is an envelope, not a full config cap" do
    capacity = %{@full | max: 8, configured: 8, effective: 2}

    assert CapacityBinding.binding(capacity) == {:envelope, 2}
    assert CapacityBinding.short_label({:envelope, 2}) == "AIMD envelope"
  end

  test "paused reservations outrank the envelope: slots exist but are held" do
    capacity = %{@full | active: 1, occupied: 2, reserved_paused: 1, max: 4, configured: 4, effective: 4}

    assert CapacityBinding.binding(capacity) == {:paused_reservations, 1}
    assert CapacityBinding.short_label({:paused_reservations, 1}) == "paused reservations=1"
  end

  test "a session override is reported as such, never as the config cap" do
    override = %{@full | configured: 16, session_override?: true}

    assert CapacityBinding.binding(override) == {:session_cap, 2}
    assert CapacityBinding.binding(@full) == {:config_cap, 2}
  end

  test "free slots with no queued demand are a supply problem, not a capacity one" do
    capacity = %{@full | occupied: 0, available: 2, queued_demand?: false}

    assert CapacityBinding.binding(capacity, %{tracker_snapshot_fresh?: true}) ==
             {:ticket_supply, %{ceiling: "config max_concurrent_agents"}}
  end

  # "Ticket supply" is a claim about what the daemon *saw*. A fleet that has not
  # looked recently enough cannot make it — that false explanation is #2138.
  test "a fleet that has not polled recently enough may not blame ticket supply" do
    capacity = %{@full | occupied: 0, available: 2, queued_demand?: false}

    assert CapacityBinding.binding(capacity, %{idle_backoff: %{active?: true}, next_poll_in_ms: 30_000}) ==
             {:has_not_polled, %{next_poll_in_ms: 30_000, ceiling: "config max_concurrent_agents"}}

    assert CapacityBinding.binding(capacity, %{tracker_snapshot_fresh?: false}) ==
             {:has_not_polled, %{ceiling: "config max_concurrent_agents"}}

    assert CapacityBinding.short_label({:has_not_polled, %{}}) == "has not polled yet"
  end

  # A dropped `set max-agents` leaves the fleet running on the config ceiling.
  # The provenance is what tells the operator their last command is gone.
  test "an unconstrained fleet names where its effective ceiling came from" do
    free = %{@full | occupied: 0, available: 2}

    assert CapacityBinding.binding(free) == {:none, %{ceiling: "config max_concurrent_agents"}}

    assert CapacityBinding.binding(%{free | session_override?: true}) ==
             {:none, %{ceiling: "session max_concurrent_agents"}}
  end

  test "an unreadable capacity map binds nothing" do
    assert CapacityBinding.binding(%{}) == {:none, nil}
    assert CapacityBinding.short_label({:none, nil}) == nil
  end
end
