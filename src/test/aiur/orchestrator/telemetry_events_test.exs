defmodule Aiur.Orchestrator.TelemetryEventsTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.TelemetryEvents

  @state %{running: %{"7" => %{telemetry_attempt_id: "42:attempt"}}}

  test "state changes from every writer give ordered points; unchanged and first observations give none" do
    recorder = recorder(self())

    states = ~w(in-progress ci-wait human-review rework ci-wait)

    for {from, to} <- Enum.zip(states, tl(states)) do
      TelemetryEvents.observe(@state, issue(from), issue(to), recorder: recorder)
    end

    TelemetryEvents.observe(@state, issue("ci-wait"), issue("ci-wait"), recorder: recorder)
    TelemetryEvents.observe(@state, nil, issue("ci-wait"), recorder: recorder)

    changes = drain()

    assert Enum.map(changes, &{&1.event, &1.from_state, &1.to_state}) == [
             {"state_change", "in-progress", "ci-wait"},
             {"state_change", "ci-wait", "human-review"},
             {"state_change", "human-review", "rework"},
             {"state_change", "rework", "ci-wait"}
           ]

    assert Enum.all?(changes, &(&1.ticket == "42" and &1.attempt_id == "42:attempt" and &1.cause == "observed"))
  end

  test "a removed or terminal blocker gives dependency_cleared with its cause; an added blocker gives none" do
    recorder = recorder(self())
    open = %{id: "b1", identifier: "11", state: "in-progress"}
    other = %{id: "b2", identifier: "12", state: "in-progress"}
    previous = %{issue("todo") | blocked_by: [open, other]}

    TelemetryEvents.observe(@state, previous, %{previous | blocked_by: [%{open | state: "done"}, other]}, recorder: recorder)
    TelemetryEvents.observe(@state, previous, %{previous | blocked_by: [open]}, recorder: recorder)
    TelemetryEvents.observe(@state, %{previous | blocked_by: []}, previous, recorder: recorder)

    assert Enum.map(drain(), &{&1.event, &1.blocker, &1.cause}) == [
             {"dependency_cleared", "11", "terminal"},
             {"dependency_cleared", "12", "removed"}
           ]
  end

  defp issue(state), do: %Issue{id: "7", identifier: "42", state: state, blocked_by: []}

  defp recorder(test_pid), do: fn :lifecycle, attributes, _opts -> send(test_pid, {:recorded, attributes}) end

  defp drain do
    receive do
      {:recorded, attributes} -> [attributes | drain()]
    after
      0 -> []
    end
  end
end
