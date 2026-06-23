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
      latest_with_event = await_render("💬 42 pushed")

      assert latest_with_event =~ "💬 42 pushed", "events box should render the event"

      # Trigger a subsequent render via :refresh_tick. This is the bug
      # surface: if debug_events is stripped from render_state, the
      # events box goes empty here.
      send(pid, :refresh_tick)
      latest_after_refresh = await_render("💬 42 pushed")

      assert latest_after_refresh =~ "💬 42 pushed",
             "events box MUST still show event after refresh_tick"
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
        # Wait for each event to land so the accumulation order is
        # deterministic, not dependent on a fixed sleep under load.
        await_render("💬 #{i} pushed")
      end

      send(pid, :refresh_tick)
      final = await_render("💬 3 pushed")

      assert final =~ "💬 1 pushed"
      assert final =~ "💬 2 pushed"
      assert final =~ "💬 3 pushed"

      pos_1 = :binary.match(final, "💬 1 pushed") |> elem(0)
      pos_2 = :binary.match(final, "💬 2 pushed") |> elem(0)
      pos_3 = :binary.match(final, "💬 3 pushed") |> elem(0)
      assert pos_1 < pos_2 and pos_2 < pos_3
    end

    test "event arrives via DebugLog broadcast and renders persistently", %{pid: pid} do
      drain_renders()

      DebugLog.broadcast(:publish, "ticket.7.pr.merged", id: 99)
      latest_with_event = await_render("💬 7 merged a PR")

      assert latest_with_event =~ "💬 7 merged a PR"

      send(pid, :refresh_tick)
      latest_after_refresh = await_render("💬 7 merged a PR")

      assert latest_after_refresh =~ "💬 7 merged a PR",
             "event MUST persist across refresh tick"
    end
  end

  # Poll rendered frames until one contains `expected`, returning that
  # frame (ANSI-stripped). Replaces fixed `Process.sleep` + `drain_latest`,
  # which raced under CPU load: the assert could run before the event was
  # applied to a frame (latest == nil → FunctionClauseError in =~) or on a
  # stale frame missing the newest event. On timeout, returns the most
  # recent frame seen — or a sentinel string when nothing ever rendered —
  # so the caller's `assert =~` always fails with a readable message
  # instead of a FunctionClauseError.
  @await_timeout_ms 2_000

  defp await_render(expected) do
    deadline = System.monotonic_time(:millisecond) + @await_timeout_ms
    await_render(expected, deadline, nil)
  end

  defp await_render(expected, deadline, last) do
    latest = drain_latest(last)
    visible_latest = visible(latest)

    cond do
      is_binary(visible_latest) and visible_latest =~ expected ->
        visible_latest

      System.monotonic_time(:millisecond) >= deadline ->
        visible_latest || "<no frame rendered within #{@await_timeout_ms}ms>"

      true ->
        Process.sleep(10)
        await_render(expected, deadline, latest)
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

  # Drain all pending {:rendered, _} and return the most recent raw payload
  # (or `acc` if none arrived). `visible/1` strips ANSI / OSC 8 hyperlink
  # escapes so string-match assertions stay readable.
  defp drain_latest(acc) do
    receive do
      {:rendered, body} -> drain_latest(body)
    after
      50 -> acc
    end
  end

  defp visible(nil), do: nil

  defp visible(text) when is_binary(text) do
    text
    |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
    |> String.replace(~r/\e\]8;;[^\e\a]*(\e\\|\a)/, "")
  end
end
