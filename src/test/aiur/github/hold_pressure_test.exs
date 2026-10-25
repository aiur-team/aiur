defmodule Aiur.GitHub.HoldPressureTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.HoldPressure

  setup do
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    start_supervised!({HoldPressure, name: name})
    %{name: name}
  end

  test "counts holds per resource over the last minute only", %{name: name} do
    hold = %{reason: :shared_budget, resource: "core"}

    assert HoldPressure.record(hold, name: name, now_ms: 0) == hold
    HoldPressure.record(hold, name: name, now_ms: 30_000)
    HoldPressure.record(%{hold | resource: "graphql"}, name: name, now_ms: 50_000)

    assert HoldPressure.per_minute(name: name, now_ms: 59_000) == %{"core" => 2, "graphql" => 1}
    # The hold at 0 has aged out of the window; the others have not.
    assert HoldPressure.per_minute(name: name, now_ms: 61_000) == %{"core" => 1, "graphql" => 1}
    assert HoldPressure.status_line(name: name, now_ms: 61_000) == "GITHUB HOLDS core=1/min graphql=1/min search=0/min"
  end

  test "a monitor that is not running reads as unavailable, never as zero holds", %{name: name} do
    stop_supervised!(HoldPressure)

    assert HoldPressure.record(%{resource: "core"}, name: name) == %{resource: "core"}
    assert HoldPressure.per_minute(name: name) == :unavailable
    assert HoldPressure.status_line(name: name) == "GITHUB HOLDS unavailable"
    # Losing the count must not silence a stuck ticket.
    assert HoldPressure.dispatch_decline("1", name: name) == :attention
  end

  test "a ticket needs attention on the third consecutive decline at any spacing", %{name: name} do
    # Default threshold: 3. The run is counted, not timed: 300 s apart (a slow
    # dispatch poll) must escalate exactly like 1 s apart.
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 0) == :transient
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 300_000) == :transient
    assert HoldPressure.dispatch_decline("2", name: name, now_ms: 300_500) == :transient
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 600_000) == :attention
    # A hold that still has not cleared stays escalated.
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 3_600_000) == :attention
  end

  test "a cleared ticket starts a fresh run", %{name: name} do
    assert HoldPressure.dispatch_decline("1", name: name) == :transient
    assert HoldPressure.dispatch_decline("1", name: name) == :transient
    assert HoldPressure.dispatch_cleared("1", name: name) == :ok
    assert HoldPressure.dispatch_decline("1", name: name) == :transient
  end
end
