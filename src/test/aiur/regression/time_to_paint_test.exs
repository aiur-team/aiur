defmodule Aiur.Regression.TimeToPaintTest do
  @moduledoc """
  Regression for "pressing Enter on an agent shows nothing for 5-10 s
  while opencode-serve handshakes complete" (perf redesign, 2026-05-21).

  Non-negotiable user requirement: a visible pane MUST appear within
  ~500 ms of Enter regardless of opencode readiness. Achieved via U3's
  placeholder pane (spawned eagerly, swapped for the real attach
  when ready).

  Two-part verification:

  1. **Source-level wiring guard.** `PaneManager.open_opencode_pane`
     MUST spawn a placeholder pane before doing any slot work — the
     fast path the user feels.

  2. **Perf-log assertion (`:perf_regression` tag).** Reads the most
     recent `aiur_perf phase=placeholder_visible` event from
     log/aiur.log and asserts wall_ms is below threshold. Catches
     regressions that re-introduce slow synchronous opens.
  """

  use ExUnit.Case, async: true

  @pane_manager_source Path.expand("../../../lib/aiur/pane_manager.ex", __DIR__)
  @log_path Path.expand("../../../log/aiur.log", __DIR__)
  @placeholder_visible_threshold_ms 500

  describe "source-level wiring" do
    test "open_opencode_pane spawns a placeholder pane before driving the slot" do
      source = File.read!(@pane_manager_source)

      assert source =~ ~r/spawn_placeholder_pane\(state, identifier\)/,
             """
             open_opencode_pane MUST call spawn_placeholder_pane before
             the async drive_real_attach. Without the placeholder, the
             user stares at an unchanged screen for the duration of the
             slot.select call (potentially seconds).
             """

      assert source =~ ~r/Task\.start\(fn -> drive_real_attach/,
             """
             open_opencode_pane MUST dispatch drive_real_attach in a
             Task so the GenServer call returns immediately. A blocking
             slot.select inside the handler defeats the placeholder.
             """
    end

    test "PaneManager handles :placeholder_swap with swap-pane" do
      source = File.read!(@pane_manager_source)

      assert source =~ ~r/def handle_info\(\{:placeholder_swap,/,
             "PaneManager MUST have a handle_info({:placeholder_swap, ...}) clause"

      assert source =~ ~r/swap-pane -s #\{real_pane_id\} -t #\{placeholder_pane_id\}/,
             """
             The swap MUST use tmux swap-pane to atomically replace
             the placeholder with the real attach. kill+spawn would
             flash empty layout and lose tmux selection state.
             """
    end
  end

  describe "log-asserted time-to-paint @tag :perf_regression" do
    @describetag :perf_regression

    test "most recent placeholder_visible event reports wall_ms below threshold" do
      unless File.exists?(@log_path) do
        flunk("""
        #{@log_path} does not exist — boot aiur via scripts/aiurdev and
        open at least one agent chat, then re-run.
        """)
      end

      log = File.read!(@log_path)

      events =
        Regex.scan(
          ~r/aiur_perf phase=placeholder_spawn_done .* wall_ms=(\d+) identifier=(\S+) pane_id=(\S+)/,
          log,
          capture: :all_but_first
        )

      if events == [] do
        flunk("""
        No `aiur_perf phase=placeholder_spawn_done` events found in
        #{@log_path}. Open at least one agent chat via scripts/aiurdev,
        then re-run.
        """)
      end

      [wall_ms_str, identifier, pane_id] = List.last(events)
      wall_ms = String.to_integer(wall_ms_str)

      assert wall_ms <= @placeholder_visible_threshold_ms,
             """
             Last placeholder_spawn_done took #{wall_ms} ms — exceeds
             #{@placeholder_visible_threshold_ms} ms threshold.
             identifier=#{identifier} pane_id=#{pane_id}

             Investigate what slowed down tmux split-window or the
             pre-placeholder bookkeeping in open_opencode_pane.
             """
    end
  end
end
