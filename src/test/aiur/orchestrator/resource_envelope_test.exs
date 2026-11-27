defmodule Aiur.Orchestrator.ResourceEnvelopeTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.ResourceEnvelope

  test "needs a fresh healthy hold before each one-slot increase and stops at the cap" do
    initial = {1, ResourceEnvelope.boot()}

    states =
      Enum.scan([0, 59_999, 60_000, 60_001, 120_000, 180_000], initial, fn stamp, state ->
        step(state, stamp, [ResourceEnvelope.binding(:cpu_psi, :healthy, stamp)], 3)
      end)

    assert Enum.map(states, &elem(&1, 0)) == [1, 1, 2, 2, 3, 3]
    assert {3, %{binding: %{signal: :configured_cap, condition: :at_limit}}} = List.last(states)
  end

  test "pressure halves immediately and reports the binding reading even when another signal is unknown" do
    reading = ResourceEnvelope.binding(:memory_psi, :pressure, 10)
    unknown = ResourceEnvelope.binding(:provider_budget, :unknown, nil)
    initial = {9, ResourceEnvelope.boot()}

    assert {4, state} = step(initial, 2_000, [unknown, reading])
    assert state.binding == reading
    assert {4, ^state} = step({4, state}, 2_000, [reading])
    assert {2, _} = step({4, state}, 2_001, [reading])
    assert ResourceEnvelope.label(%{resource_binding: state.binding}, 8_010) == "memory_psi (pressure, sample age 8s ago)"
  end

  test "missing provider readings hold the current ceiling and reset the healthy streak" do
    healthy = ResourceEnvelope.binding(:provider_budget, :healthy, 0)
    unknown = ResourceEnvelope.binding(:provider_budget, :unknown, nil)
    initial = step({4, ResourceEnvelope.boot()}, 0, [healthy])

    assert {4, state} = held = step(initial, 60_000, [unknown])
    assert state.binding == unknown
    assert ResourceEnvelope.label(%{resource_binding: state.binding}, 60_000) == "provider_budget (unknown, sample age unavailable)"
    assert {4, _} = recovering = step(held, 120_000, [healthy])
    assert {5, _} = step(recovering, 180_000, [healthy])
  end

  test "active build work and gaps in sampling interrupt the healthy hold" do
    healthy = ResourceEnvelope.binding(:build_gate, :healthy, 0)
    busy = ResourceEnvelope.binding(:build_gate, :busy, 30_000)
    initial = step({4, ResourceEnvelope.boot()}, 0, [healthy])

    assert {4, %{binding: ^busy}} = held = step(initial, 30_000, [busy])
    assert {4, _} = recovering = step(held, 60_000, [healthy])
    assert {4, _} = step(recovering, 250_000, [healthy])
  end

  defp step({level, envelope}, stamp, readings, limit \\ 10) do
    ResourceEnvelope.step(envelope, level, limit, :configured_cap, readings, {stamp, 60_000, 120_000}, true)
  end
end
