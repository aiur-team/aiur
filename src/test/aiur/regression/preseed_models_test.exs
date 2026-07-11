defmodule Aiur.Regression.PreseedModelsTest do
  @moduledoc """
  Regression for "first open of every agent paid a ~6s opencode-serve
  rebuild because the slot's models map was empty at boot" (perf
  redesign, 2026-05-21).

  The slot MUST pre-seed `known_identifiers` from the orchestrator
  at boot so the first open of any active agent hits the warm
  `identifier_known?` path. Without this, every first open triggers
  `schedule_serve_rebuild` (~6s opencode-serve restart) and the pre-
  warm chain provides no perceived value.
  """

  use ExUnit.Case, async: true

  @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)
  @serve_lifecycle_source Path.expand("../../../lib/aiur/opencode/slot/serve_lifecycle.ex", __DIR__)

  test "handle_continue(:start_serve) calls Orchestrator.list_active_identifiers when known_identifiers is empty" do
    source = File.read!(@slot_source)
    block = extract_start_serve(source)

    assert block =~ ~r/safely_list_active_identifiers|Orchestrator\.list_active_identifiers/,
           """
           handle_continue(:start_serve) MUST read the active identifier
           list from the orchestrator when known_identifiers is empty
           (initial pre-warm). Without this seed, every first open of
           every agent triggers a ~6 s opencode-serve rebuild and the
           pre-warm provides no perceived value.
           """
  end

  test "safely_list_active_identifiers is a guarded call (orchestrator may not be up yet)" do
    source = File.read!(@serve_lifecycle_source)

    assert source =~ ~r/def safely_list_active_identifiers/,
           "safely_list_active_identifiers/0 must exist as a guarded wrapper"

    assert source =~ ~r/rescue\s*\n\s*_\s*->\s*\[\]|catch\s*\n\s*_\s*,\s*_\s*->\s*\[\]/,
           """
           safely_list_active_identifiers MUST tolerate orchestrator
           unavailability — the slot still boots and falls back to
           the empty-map path. Don't crash slot init if the orchestrator
           hasn't started yet.
           """
  end

  defp extract_start_serve(source) do
    case Regex.run(~r/def handle_continue\(:start_serve.*?\n  end\n/s, source) do
      [match | _] -> match
      _ -> raise "could not extract handle_continue(:start_serve)"
    end
  end
end
