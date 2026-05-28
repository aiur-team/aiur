defmodule Aiur.AgentList.AppDebugEventsPersistenceTest do
  @moduledoc """
  Regression test for the "events flash and disappear" bug.

  Drives the real `Aiur.AgentList.App` GenServer (not just the renderer
  in isolation), captures every iodata write via an injected `write_fun`,
  and asserts that the most-recent debug event is present in the LAST
  frame after one event arrival followed by a refresh tick.

  This catches the original failure mode: `defp render/1` building a
  render_state via `Map.take` + `Map.put` that didn't include
  `debug_events`, so post-event refresh ticks would re-render with an
  empty ticker.
  """

  use ExUnit.Case, async: false

  alias Aiur.AgentList.App
  alias Aiur.Events.DebugLog

  setup do
    parent = self()
    write_fun = fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end

    # subscribe?: true is required so the App subscribes to the
    # DebugLog topic; the test relies on that path firing.
    {:ok, pid} =
      App.start_link(
        write_fun: write_fun,
        name: nil,
        subscribe?: true,
        debug?: true
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{pid: pid}
  end

  describe "debug events persist across renders" do
    test "event survives a subsequent refresh-tick render", %{pid: pid} do
      drain_renders()

      entry = %{
        kind: :publish,
        topic: "ticket.42.branch.push",
        id: 4287,
        identifier: nil,
        at: System.monotonic_time(:millisecond)
      }

      send(pid, {:event_debug, entry})
      Process.sleep(100)
      latest_with_event = drain_latest()

      assert latest_with_event =~ "id=4287", "ticker should render the event"

      # Trigger a subsequent render via :refresh_tick. This is the bug
      # surface: if debug_events is stripped from render_state, the
      # ticker goes empty here.
      send(pid, :refresh_tick)
      Process.sleep(100)
      latest_after_refresh = drain_latest()

      assert latest_after_refresh =~ "id=4287",
             "ticker MUST still show event after refresh_tick"
    end

    test "multiple events accumulate (newest at bottom)", %{pid: pid} do
      drain_renders()

      for i <- 1..3 do
        entry = %{
          kind: :publish,
          topic: "ticket.#{i}.branch.push",
          id: i,
          identifier: nil,
          at: System.monotonic_time(:millisecond)
        }

        send(pid, {:event_debug, entry})
        Process.sleep(50)
      end

      send(pid, :refresh_tick)
      Process.sleep(100)
      final = drain_latest()

      assert final =~ "id=1"
      assert final =~ "id=2"
      assert final =~ "id=3"

      pos_1 = :binary.match(final, "id=1") |> elem(0)
      pos_2 = :binary.match(final, "id=2") |> elem(0)
      pos_3 = :binary.match(final, "id=3") |> elem(0)
      assert pos_1 < pos_2 and pos_2 < pos_3
    end

    test "event arrives via DebugLog broadcast and renders persistently", %{pid: pid} do
      drain_renders()

      DebugLog.broadcast(:publish, "ticket.7.pr.merged", id: 99)
      Process.sleep(100)
      latest_with_event = drain_latest()

      assert latest_with_event =~ "id=99"

      send(pid, :refresh_tick)
      Process.sleep(100)
      latest_after_refresh = drain_latest()

      assert latest_after_refresh =~ "id=99",
             "event MUST persist across refresh tick"
    end
  end

  # Drain any pending {:rendered, _} messages from the test process mailbox.
  defp drain_renders do
    receive do
      {:rendered, _} -> drain_renders()
    after
      50 -> :ok
    end
  end

  # Drain all pending {:rendered, _} and return the most recent payload.
  defp drain_latest, do: drain_latest(nil)

  defp drain_latest(acc) do
    receive do
      {:rendered, body} -> drain_latest(body)
    after
      50 -> acc
    end
  end
end
