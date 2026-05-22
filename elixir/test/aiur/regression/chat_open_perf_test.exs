defmodule Aiur.Regression.ChatOpenPerfTest do
  @moduledoc """
  Performance regression for "opening a chat pane takes too long"
  (reported 2026-05-21: ~17 s pane spawn + 7 s convo render).

  Reads `elixir/log/aiur.log` and asserts the most recent
  `aiur_pane_manager phase=open_visible` event reports an `open_ms`
  below a generous threshold. Catches regressions that re-introduce
  slow rebuild paths or extra serve/attach respawns.

  Tagged `:perf_regression` so CI without a live aiur can skip. To
  exercise: run `scripts/aiur`, open at least one agent chat, then:

      mix test --include perf_regression test/aiur/regression/chat_open_perf_test.exs
  """

  use ExUnit.Case, async: true

  @moduletag :perf_regression

  # Threshold derived from current measured performance with all
  # Bug A/B/C fixes applied (post-2026-05-21):
  #   - Slot pre-warm hits :ready at ~9 s (opencode-serve cold start)
  #   - First open on a pre-warmed slot 1 incurs:
  #       * identifier_miss serve rebuild: ~5-6 s
  #       * session writer await_replay:  ~1.5 s
  #       * attach respawn with --session: ~100 ms
  #     Total open_ms ≈ 7-8 s.
  #
  # Threshold = 12_000 ms gives ~50 % headroom over current.
  # If this fires, investigate WHY rebuilds got slower — don't
  # silently raise the threshold.
  @open_ms_threshold 12_000

  @log_path Path.expand("../../../log/aiur.log", __DIR__)

  test "most recent open_visible reports open_ms below threshold" do
    unless File.exists?(@log_path) do
      flunk("""
      #{@log_path} does not exist — boot aiur via scripts/aiur and
      open at least one agent chat, then re-run.
      """)
    end

    log = File.read!(@log_path)

    open_events =
      Regex.scan(
        ~r/aiur_pane_manager phase=open_visible elapsed_ms=\d+ open_ms=(\d+)\s+identifier=(\S+)\s+slot=(\d+)\s+pane_id=(\S+)/,
        log,
        capture: :all_but_first
      )

    if open_events == [] do
      flunk("""
      No `aiur_pane_manager phase=open_visible` events found in #{@log_path}.
      Open at least one agent chat via scripts/aiur, then re-run.
      """)
    end

    [open_ms_str, identifier, slot, pane_id] = List.last(open_events)
    open_ms = String.to_integer(open_ms_str)

    assert open_ms <= @open_ms_threshold,
           """
           Last open_visible event took #{open_ms} ms — exceeds threshold #{@open_ms_threshold} ms.

           identifier=#{identifier} slot=#{slot} pane_id=#{pane_id}

           If this is a real regression, investigate what slowed down the
           open path (see commit history for opencode/slot.ex, pane_manager.ex).
           If the slowdown is intentional and unavoidable, raise the
           threshold and add a comment explaining why.
           """
  end
end
