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

  test "a ticket needs attention only at the threshold within the window", %{name: name} do
    # Defaults: 3 declines within 600 seconds.
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 0) == :transient
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 1_000) == :transient
    assert HoldPressure.dispatch_decline("2", name: name, now_ms: 1_500) == :transient
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 2_000) == :attention

    # The three declines aged out, so the next one starts a fresh count.
    assert HoldPressure.dispatch_decline("1", name: name, now_ms: 700_000) == :transient
  end
end
