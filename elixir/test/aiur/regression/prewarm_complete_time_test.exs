defmodule Aiur.Regression.PrewarmCompleteTimeTest do
  @moduledoc """
  Regression for "AttachPool's slot-allocation race causes prewarm to
  take 17-37 s per agent" (reported 2026-05-21).

  Observed bug: `maybe_warm_pending/1` calls `SlotSupervisor.acquire_slot/0`
  in a tight reduce loop. Each call spawns a Task that drives
  `Slot.select` asynchronously. The slot's status doesn't transition
  from `:ready` to `:active` until the Task's first message lands
  inside the slot worker — leaving a several-hundred-millisecond
  window where the SAME slot is returned to multiple calls in the
  loop. Two warmings collide on slot 1; both hit the 30 s paint
  timeout because the pane content flips between sessions.

  Acceptance: ALL pre-warmed ⚡ identifiers reach :warm within
  ~20 s of `slot_chain_complete` (5-6 s opencode-attach paint per
  identifier, fully parallel across distinct slots). The two timeouts
  observed (id=5 wall_ms=30770, id=6 wall_ms=31383) prove the race —
  each was 30 s+ because they were paint-fighting.

  Threshold: 18 s from `slot_chain_complete` to the LAST
  `attach_pool_warm` event. Post-fix measured worst: 15011 ms (id=7,
  3 agents warming in parallel). Buffer: ~3 s for CPU contention
  jitter from N Node.js processes booting concurrently. If the test
  fails at 17 s / 37 s, inspect for the slot race or any other
  regression that re-introduces serial warming.
  """

  use ExUnit.Case, async: true

  @attach_pool_source Path.expand("../../../lib/aiur/opencode/attach_pool.ex", __DIR__)
  @log_path Path.expand("../../../log/aiur.log", __DIR__)
  @max_prewarm_ms 18_000

  describe "source-level wiring (always runs)" do
    test "AttachPool tracks claimed slots to avoid acquire_slot race" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/claimed_slots/,
             """
             AttachPool MUST track which slots it has already handed
             out to in-flight warm Tasks. SlotSupervisor.acquire_slot
             returns the lowest-indexed :ready slot — without a
             claimed-set guard, calling it back-to-back in
             maybe_warm_pending returns the SAME slot multiple times
             (the slot's status hasn't transitioned to :active yet
             when the Task is dispatched asynchronously).

             Without this guard: two warmings collide on the same
             slot, both fight for the pane, both hit the 30 s paint
             timeout. ⚡ appears at 30-40 s per agent instead of
             5-7 s.
             """
    end

    test "AttachPool releases claimed slot when the warm Task finishes" do
      source = File.read!(@attach_pool_source)

      # Whether the Task succeeded or failed, the claim must be released
      # so the slot can be re-warmed for a different agent later
      # (e.g. after :attach_consumed frees the slot back).
      assert source =~ ~r/claimed_slots.*MapSet\.delete|MapSet\.delete\(.*claimed_slots|release_claim/,
             """
             AttachPool MUST release a slot from claimed_slots when
             the warm task completes (success or failure). Otherwise
             the pool leaks claims and eventually thinks no slots
             are available.
             """
    end
  end

  describe "perf-log assertion @tag :perf_regression" do
    @describetag :perf_regression

    test "last attach_pool_warm event fires within #{@max_prewarm_ms} ms of slot_chain_complete" do
      unless File.exists?(@log_path) do
        flunk("""
        #{@log_path} does not exist — boot aiur via scripts/aiur,
        wait for all ⚡ to appear, then re-run.
        """)
      end

      log = File.read!(@log_path)

      # Find the most-recent boot's slot_chain_complete event.
      chain_completes =
        Regex.scan(
          ~r/aiur_perf phase=slot_chain_complete at_ms=(-?\d+) elapsed_ms=(\d+)/,
          log,
          capture: :all_but_first
        )

      if chain_completes == [] do
        flunk("No slot_chain_complete events found in #{@log_path}.")
      end

      [chain_at_ms_str, chain_elapsed_str] = List.last(chain_completes)
      chain_at_ms = String.to_integer(chain_at_ms_str)
      chain_elapsed = String.to_integer(chain_elapsed_str)

      # Find all attach_pool_warm events AFTER that chain_complete.
      warm_events =
        Regex.scan(
          ~r/aiur_perf phase=attach_pool_warm at_ms=(-?\d+) elapsed_ms=\d+ identifier=(\S+) slot=(\d+) pane_id=(\S+)/,
          log,
          capture: :all_but_first
        )
        |> Enum.filter(fn [at_ms_str | _] ->
          String.to_integer(at_ms_str) >= chain_at_ms
        end)

      if warm_events == [] do
        flunk("""
        Found slot_chain_complete at elapsed_ms=#{chain_elapsed} but
        no subsequent attach_pool_warm events. Either the pool didn't
        seed (no active agents) or all warmings failed.
        """)
      end

      [last_warm_at_str | _] = List.last(warm_events)
      last_warm_at_ms = String.to_integer(last_warm_at_str)
      prewarm_duration_ms = last_warm_at_ms - chain_at_ms

      identifiers_warmed =
        warm_events
        |> Enum.map(fn [_, id | _] -> id end)
        |> Enum.uniq()

      assert prewarm_duration_ms <= @max_prewarm_ms,
             """
             Pre-warm chain took #{prewarm_duration_ms} ms to complete
             (chain_complete -> last attach_pool_warm). Threshold:
             #{@max_prewarm_ms} ms.

             Warmed #{length(identifiers_warmed)} identifiers:
             #{Enum.join(identifiers_warmed, ", ")}

             User observed ⚡ appearing at 17 / 37 / 38 s (run on
             2026-05-21). Symptoms:
               - attach_pool_warm_attach_done events with
                 result=paint_timeout wall_ms~30000
               - Multiple attach_pool_warm_attach_start events for
                 the same slot index in rapid succession
             That indicates the AttachPool slot-allocation race —
             two warmings landing on the same slot. Check
             maybe_warm_pending/1 in attach_pool.ex.
             """
    end

    test "no attach_pool_warm_attach result=paint_timeout in the most recent run" do
      unless File.exists?(@log_path) do
        flunk("#{@log_path} does not exist")
      end

      log = File.read!(@log_path)

      # Find the most-recent boot's slot_chain_complete.
      chain_completes =
        Regex.scan(
          ~r/aiur_perf phase=slot_chain_complete at_ms=(-?\d+)/,
          log,
          capture: :all_but_first
        )

      chain_at_ms =
        case chain_completes do
          [] -> 0
          _ -> chain_completes |> List.last() |> List.first() |> String.to_integer()
        end

      timeouts =
        Regex.scan(
          ~r/aiur_perf phase=attach_pool_warm_attach_done at_ms=(-?\d+) .* result=paint_timeout identifier=(\S+) slot=(\d+)/,
          log,
          capture: :all_but_first
        )
        |> Enum.filter(fn [at_ms_str | _] ->
          String.to_integer(at_ms_str) >= chain_at_ms
        end)

      assert timeouts == [],
             """
             Found #{length(timeouts)} attach_pool_warm_attach paint
             timeouts in the most-recent run:

             #{Enum.map_join(timeouts, "\n", fn [_, id, s] -> "  identifier=#{id} slot=#{s}" end)}

             A paint timeout means opencode-attach was spawned in
             that slot but never rendered the `Build · issue-` marker
             within the 30 s budget. Almost always indicates two
             warmings colliding on the same slot.
             """
    end
  end
end
