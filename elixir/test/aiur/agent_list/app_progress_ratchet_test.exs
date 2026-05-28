defmodule Aiur.AgentList.AppProgressRatchetTest do
  @moduledoc """
  Source-aware progress ratchet:

    - `agent.progress.checkin` (operator-driven 1–10 estimate)
      ALWAYS records, even when the new percent is lower than the
      current head — the agent's attested value trumps phase guesses.
    - `agent.progress.phase` and the bare `agent.progress`
      topic only record when the new percent is greater than or equal
      to the current head — phase events can ratchet up (pr.opened →
      100) but cannot drag a checkin-attested floor back down.
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

  defp send_progress(pid, id, percent, source) do
    topic =
      case source do
        :checkin -> "ticket.#{id}.agent.progress.checkin"
        :phase -> "ticket.#{id}.agent.progress.phase"
        :bare -> "ticket.#{id}.agent.progress"
      end

    send(
      pid,
      {:event_debug,
       %{
         kind: :publish,
         topic: topic,
         id: System.unique_integer([:positive]),
         identifier: nil,
         body: %{"percent" => percent},
         at: System.monotonic_time(:millisecond)
       }}
    )

    # Let the cast fold the entry.
    Process.sleep(20)
  end

  defp head_percent(pid, id) do
    snapshot = App.snapshot(pid)

    case Map.get(snapshot.progress_by_id, id, []) do
      [{percent, _ts} | _] -> percent
      _ -> nil
    end
  end

  test "phase events ratchet up but cannot lower the head", %{pid: pid} do
    send_progress(pid, "R1", 40, :phase)
    assert head_percent(pid, "R1") == 40

    send_progress(pid, "R1", 20, :phase)
    assert head_percent(pid, "R1") == 40, "phase event below head must be ignored"

    send_progress(pid, "R1", 70, :phase)
    assert head_percent(pid, "R1") == 70, "phase event above head must update"
  end

  test "checkin always wins — even when it lowers the head", %{pid: pid} do
    send_progress(pid, "R2", 80, :phase)
    assert head_percent(pid, "R2") == 80

    send_progress(pid, "R2", 30, :checkin)
    assert head_percent(pid, "R2") == 30, "agent check-in trumps prior phase guess"

    send_progress(pid, "R2", 10, :checkin)
    assert head_percent(pid, "R2") == 10, "consecutive check-ins always win"
  end

  test "phase event below a recent checkin floor stays ignored", %{pid: pid} do
    send_progress(pid, "R3", 60, :checkin)
    send_progress(pid, "R3", 50, :phase)
    assert head_percent(pid, "R3") == 60, "phase can't drag below the checkin floor"

    send_progress(pid, "R3", 100, :phase)
    assert head_percent(pid, "R3") == 100, "phase above the floor still ratchets up"
  end

  test "bare `agent.progress` topic behaves like phase", %{pid: pid} do
    send_progress(pid, "R4", 50, :bare)
    assert head_percent(pid, "R4") == 50

    send_progress(pid, "R4", 30, :bare)
    assert head_percent(pid, "R4") == 50, "bare progress below head must be ignored"

    send_progress(pid, "R4", 90, :bare)
    assert head_percent(pid, "R4") == 90
  end
end
