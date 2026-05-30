defmodule Aiur.AgentList.AppPhaseTrackingTest do
  @moduledoc """
  `phase_by_identifier` folds `ticket.<id>.agent.phase.<phase>.start`
  and `.end` publishes into a per-id active-phase map that drives the
  running-state status emoji (#68):

    - `.start` sets the phase (last start wins).
    - `.end` clears it only when it matches the currently-tracked
      phase, so a late `.end` for a superseded phase can't wipe a newer
      `.start`.
  """

  use ExUnit.Case, async: false

  alias Aiur.AgentList.App

  setup do
    parent = self()
    write_fun = fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end

    {:ok, pid} =
      App.start_link(
        write_fun: write_fun,
        name: nil,
        subscribe?: false,
        debug?: false
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid}
  end

  defp send_phase(pid, id, phase, edge) do
    send(
      pid,
      {:event_debug,
       %{
         kind: :publish,
         topic: "ticket.#{id}.agent.phase.#{phase}.#{edge}",
         id: System.unique_integer([:positive]),
         identifier: nil,
         body: %{},
         at: System.monotonic_time(:millisecond)
       }}
    )

    Process.sleep(20)
  end

  defp phase_of(pid, id) do
    App.snapshot(pid).phase_by_identifier |> Map.get(id)
  end

  test "phase.start sets the active phase, last start wins", %{pid: pid} do
    send_phase(pid, "P1", "brainstorm", "start")
    assert phase_of(pid, "P1") == :brainstorm

    send_phase(pid, "P1", "plan", "start")
    assert phase_of(pid, "P1") == :plan

    send_phase(pid, "P1", "work", "start")
    assert phase_of(pid, "P1") == :work
  end

  test "phase.end clears the active phase when it matches", %{pid: pid} do
    send_phase(pid, "P2", "review", "start")
    assert phase_of(pid, "P2") == :review

    send_phase(pid, "P2", "review", "end")
    assert phase_of(pid, "P2") == nil
  end

  test "a late .end for a superseded phase does not wipe the newer phase", %{pid: pid} do
    send_phase(pid, "P3", "plan", "start")
    send_phase(pid, "P3", "work", "start")
    assert phase_of(pid, "P3") == :work

    # `.end` for the superseded `plan` phase must not clear the active
    # `work` phase.
    send_phase(pid, "P3", "plan", "end")
    assert phase_of(pid, "P3") == :work
  end

  test "phases for different identifiers are tracked independently", %{pid: pid} do
    send_phase(pid, "P4", "brainstorm", "start")
    send_phase(pid, "P5", "review", "start")

    assert phase_of(pid, "P4") == :brainstorm
    assert phase_of(pid, "P5") == :review
  end
end
