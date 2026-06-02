defmodule Aiur.Regression.ParallelPreWarmTest do
  @moduledoc """
  Regression for "slot pre-warm chain was serial — slot N+1 waited for
  slot N to be :ready" (perf redesign, 2026-05-21).

  Five slots warming sequentially at ~6 s each = ~30 s before the full
  set is ready. Parallel pre-warm cuts the chain to ~one opencode-serve
  startup time (~7 s wall) by starting all slots up-front and letting
  them warm concurrently.

  Source-level guard: SlotPolicy.handle_info(:start_first_slot, ...)
  MUST start every slot in the target_count range up-front, not just
  slot 1. The previous serial chain pattern (start slot 1, wait for
  :slot_ready, start slot 2) is forbidden.
  """

  use ExUnit.Case, async: true

  @moduletag :skip

  @policy_source Path.expand("../../../lib/aiur/opencode/slot_policy.ex", __DIR__)

  test "slot policy starts every slot in target_count range up-front" do
    source = File.read!(@policy_source)
    block = extract_function(source, "handle_info\\(:start_first_slot,\\s*%\\{target_count:\\s*target")

    assert block =~ ~r/Enum\.reduce\(1\.\.target,/,
           """
           SlotPolicy.handle_info(:start_first_slot) MUST iterate 1..target
           and start every slot up-front. The previous serial chain
           pattern (start slot 1 then advance on :slot_ready) was costing
           ~5 s per additional slot. Parallel pre-warm collapses the
           total wall time to ~one opencode-serve startup (~7 s).
           """
  end

  test "slot_ready handler does not start the next slot (parallel mode)" do
    source = File.read!(@policy_source)

    # In serial mode, handle_info({:slot_ready, n}) called
    # SlotSupervisor.start_slot(n + 1). In parallel mode, it must NOT —
    # all slots are already started up-front.
    refute source =~ ~r/handle_info\(\{:slot_ready,[^)]*\}.*?start_slot\(next\)/s,
           """
           handle_info({:slot_ready, _}) MUST NOT call
           SlotSupervisor.start_slot/1. All slots are started up-front
           in :start_first_slot — calling start_slot on :slot_ready
           re-introduces the serial chain pattern that this redesign
           eliminated.
           """
  end

  test "parallel start emits aiur_perf :slot_chain_parallel_start" do
    source = File.read!(@policy_source)

    assert source =~ ~r/Aiur\.Perf\.event\(:slot_chain_parallel_start/,
           """
           SlotPolicy MUST emit :slot_chain_parallel_start when it
           dispatches the parallel start. This event is consumed by
           the debug-mode milestone footer and is the marker that
           parallel mode is in effect.
           """
  end

  defp extract_function(source, pattern) do
    case Regex.run(~r/def #{pattern}.*?\n  end\n/s, source) do
      [match | _] -> match
      _ -> raise "could not extract function matching #{pattern}"
    end
  end
end
