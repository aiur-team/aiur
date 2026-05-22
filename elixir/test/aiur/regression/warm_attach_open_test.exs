defmodule Aiur.Regression.WarmAttachOpenTest do
  @moduledoc """
  Regression for "when ⚡ (warm pre-attach) is showing next to an
  agent row, pressing Enter MUST open opencode in under 1 second"
  (perf redesign, 2026-05-21).

  Source-level wiring guard + perf-log assertion.

  Measured baseline (3 consecutive opens, fully rendered):
    Run 1: 118 ms, Run 2: 183 ms, Run 3: 214 ms.
  Spread across runs: 96 ms. Threshold = worst observed + ~1.5x the
  spread = 214 + 150 ≈ 364, rounded to a clean 400 ms.

  Tight enough that any real regression fires (removing the pre-resize
  jumps us back to 5-7 s); loose enough to absorb normal jitter
  (terminal/tmux latency, scheduler hiccups).

  If this fires, investigate:
    1. AttachPool's wait_for_paint may be marking warm too early
       (opencode-attach process is spawned but not yet rendered).
    2. The pre-resize to 110x30 may have been removed (opencode
       re-renders from scratch on resize, costing 5-7 s).
    3. Tmux move-pane may have changed semantics.
  """

  use ExUnit.Case, async: true

  @attach_pool_source Path.expand("../../../lib/aiur/opencode/attach_pool.ex", __DIR__)
  @pane_manager_source Path.expand("../../../lib/aiur/pane_manager.ex", __DIR__)
  @log_path Path.expand("../../../log/aiur.log", __DIR__)

  # Hard fail at threshold. Worst measured: 214 ms; spread: 96 ms.
  # Buffer of ~1.5x spread (150 ms) → 400 ms threshold.
  @warm_convo_paint_threshold_ms 400

  describe "source-level wiring (always runs)" do
    test "AttachPool waits for the `Build · issue-` paint marker before warming" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/defp wait_for_paint\(/,
             """
             AttachPool MUST poll the pane for the `Build · issue-`
             marker before flipping the identifier to :warm. Without
             this, the ⚡ icon appears before opencode-attach has
             rendered, and the user pressing Enter sees a 5-7 s
             cold render after move-pane.
             """

      assert source =~ ~r/"Build · issue-"/,
             "wait_for_paint MUST grep for the opencode message-turn marker"
    end

    test "AttachPool pre-resizes the hidden pane to visible size" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/resize-pane -t #\{pane_id\} -x \d+ -y \d+/,
             """
             AttachPool MUST resize the hidden pane to roughly the
             visible-window size BEFORE wait_for_paint. opencode-attach
             re-renders from scratch on terminal resize — without the
             pre-resize, the resize happens at move-pane time and
             the user pays the 5-7 s re-render cost.
             """
    end

    test "PaneManager.open_opencode_pane checks AttachPool first" do
      source = File.read!(@pane_manager_source)

      assert source =~ ~r/AttachPool\.consume\(identifier\)/,
             """
             PaneManager.open_opencode_pane MUST call AttachPool.consume
             FIRST. If a warm attach exists, the move-pane path is ~100x
             faster than the placeholder + respawn path.
             """

      assert source =~ ~r/move_warm_pane_visible\(state, identifier, slot_index, pane_id, from\)/,
             "PaneManager MUST have a move_warm_pane_visible/5 fast path"
    end
  end

  describe "perf-log assertion @tag :perf_regression" do
    @describetag :perf_regression

    test "warm-path opens render opencode under 750 ms threshold" do
      unless File.exists?(@log_path) do
        flunk("""
        #{@log_path} does not exist — boot aiur via scripts/aiur,
        wait for a ⚡ to appear, press Enter on that agent, then re-run.
        """)
      end

      log = File.read!(@log_path)

      # Find the most-recent warm-path open by matching
      # attach_pool_consume_hit to its convo_first_paint within the
      # same identifier+slot+pane_id triple.
      consume_events =
        Regex.scan(
          ~r/aiur_perf phase=attach_pool_consume_hit at_ms=(-?\d+) .* identifier=(\S+) slot=(\d+) pane_id=(\S+)/,
          log,
          capture: :all_but_first
        )

      if consume_events == [] do
        flunk("""
        No `aiur_perf phase=attach_pool_consume_hit` events found in
        #{@log_path}. Boot aiur in --debug mode, wait for a ⚡ next to
        an agent row, press Enter on that agent, then re-run.
        """)
      end

      [consume_at_ms_str, identifier, slot_str, pane_id] = List.last(consume_events)
      consume_at_ms = String.to_integer(consume_at_ms_str)
      slot = String.to_integer(slot_str)

      paint_events =
        Regex.scan(
          ~r/aiur_perf phase=convo_first_paint at_ms=(-?\d+) elapsed_ms=\d+ identifier=(\S+) slot=(\d+) pane_id=(\S+) wall_ms=(\d+)/,
          log,
          capture: :all_but_first
        )
        |> Enum.filter(fn [at_ms_str, id, s, pid, _wall] ->
          identifier == id and slot == String.to_integer(s) and pane_id == pid and
            String.to_integer(at_ms_str) >= consume_at_ms
        end)

      case paint_events do
        [] ->
          flunk("""
          Found warm-path consume for identifier=#{identifier} slot=#{slot}
          pane_id=#{pane_id} but no matching convo_first_paint event
          after it. opencode never rendered, or the paint detector
          timed out (default 30 s budget).
          """)

        [_ | _] ->
          [paint_at_ms_str, _, _, _, _wall_ms] = List.first(paint_events)
          paint_at_ms = String.to_integer(paint_at_ms_str)
          end_to_end_ms = paint_at_ms - consume_at_ms

          assert end_to_end_ms <= @warm_convo_paint_threshold_ms,
                 """
                 Warm-path open for identifier=#{identifier} slot=#{slot}
                 took #{end_to_end_ms} ms from consume to convo paint —
                 exceeds threshold #{@warm_convo_paint_threshold_ms} ms.

                 Threshold derived from measured baseline (worst of 3
                 consecutive opens: 214 ms) + ~1.5x spread buffer
                 (150 ms) ≈ 400 ms.

                 Investigate:
                   - AttachPool's wait_for_paint may be marking warm
                     before opencode has actually rendered.
                   - Pre-resize to 110x30 may have been removed,
                     causing opencode-attach to re-render on move-pane.
                   - tmux move-pane semantics may have changed.

                 The ⚡ icon on the agent row is a PROMISE — pressing
                 Enter on it MUST open opencode in well under 1 s.
                 Lossier than that and the user starts ignoring the
                 icon entirely.
                 """
      end
    end
  end
end
