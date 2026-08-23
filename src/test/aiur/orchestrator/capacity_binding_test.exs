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

    assert CapacityBinding.binding(capacity) == {:ticket_supply, 0}
  end

  test "an unconstrained fleet, and an unreadable capacity map, bind nothing" do
    assert CapacityBinding.binding(%{@full | occupied: 0, available: 2}) == {:none, nil}
    assert CapacityBinding.binding(%{}) == {:none, nil}
    assert CapacityBinding.short_label({:none, nil}) == nil
  end
end
