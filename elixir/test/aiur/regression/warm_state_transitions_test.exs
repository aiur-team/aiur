defmodule Aiur.Regression.WarmStateTransitionsTest do
  @moduledoc """
  Regressions for two AgentList ↔ AttachPool warm-marker bugs reported
  during a 5-agent test run on 2026-05-22:

  1. **Opening a chat regressed the row's status back to ⏳**. The
     `:attach_consumed` handler used to drop the identifier from
     `warm_identifiers`, leaving it in neither the warm nor warming
     set — the renderer's fallback then painted the warming hourglass.

  2. **Only the first agent's row ever flipped from ⏳ to ready**. When
     `wait_for_paint` timed out (common under CPU contention with many
     agents booting concurrently), AttachPool sent `:attach_failed` to
     itself only — never broadcasting it on the PubSub topic. AgentList
     stayed subscribed to `:attach_warm` / `:attach_warming` but had no
     handler for failure, so `warming_identifiers` was never trimmed
     and the rows stayed hourglass forever.
  """

  use ExUnit.Case, async: true

  @app_source Path.expand("../../../lib/aiur/agent_list/app.ex", __DIR__)
  @attach_pool_source Path.expand("../../../lib/aiur/opencode/attach_pool.ex", __DIR__)

  describe ":attach_consumed must NOT clear warm_identifiers" do
    test "AgentList keeps the identifier in warm_identifiers after consume" do
      source = File.read!(@app_source)

      consumed_block =
        case Regex.run(~r/def handle_info\(\{:attach_consumed,.*?\n  end\n/s, source) do
          [match | _] -> match
          _ -> raise "could not extract :attach_consumed handler"
        end

      # Strip Elixir line comments first so phrases like "keep it in
      # `warm_identifiers`" inside the explanatory comment don't trip
      # the refute below.
      code_only =
        consumed_block
        |> String.split("\n")
        |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
        |> Enum.join("\n")

      refute code_only =~ ~r/\bwarm_identifiers,\s*&MapSet\.delete/s,
             """
             :attach_consumed must NOT remove the identifier from
             `warm_identifiers`. Opening a chat should keep the row's
             status emoji at the warm marker — dropping it from the
             set makes the renderer fall back to ⏳ (the warming
             default), so the user sees an opened chat appear to
             "regress" to a hourglass.
             """

      assert code_only =~ ~r/warming_identifiers,\s*&MapSet\.delete/s,
             """
             :attach_consumed should still clear `warming_identifiers`
             (defensive — the warm broadcast normally already cleared
             it, but if the identifier was somehow still mid-warm,
             consuming it ends that state).
             """
    end
  end

  describe ":attach_failed must clear warming_identifiers via PubSub" do
    test "AttachPool broadcasts :attach_failed when wait_for_paint times out" do
      source = File.read!(@attach_pool_source)

      failed_block =
        case Regex.run(
               ~r/def handle_info\(\{:attach_failed, identifier, slot_index, reason\}.*?\n  end\n/s,
               source
             ) do
          [match | _] -> match
          _ -> raise "could not extract :attach_failed handler"
        end

      assert failed_block =~ ~r/broadcast_event\(\{:attach_failed,/,
             """
             AttachPool MUST call broadcast_event/1 with :attach_failed
             so AgentList subscribers can trim the ⏳ warming marker.
             Without this, paint-timed-out rows stay hourglass forever
             and Enter remains blocked.
             """
    end

    test "AgentList handles :attach_failed by clearing warming_identifiers" do
      source = File.read!(@app_source)

      assert source =~ ~r/def handle_info\(\{:attach_failed,/,
             """
             AgentList MUST have a handler for the :attach_failed
             PubSub event. Without it, identifiers whose warm task
             timed out stay in `warming_identifiers` indefinitely and
             the renderer keeps painting ⏳ for them.
             """

      failed_block =
        case Regex.run(
               ~r/def handle_info\(\{:attach_failed, identifier,.*?\n  end\n/s,
               source
             ) do
          [match | _] -> match
          _ -> raise "could not extract AgentList :attach_failed handler"
        end

      assert failed_block =~ ~r/warming_identifiers.*MapSet\.delete/s,
             """
             AgentList's :attach_failed handler MUST remove the
             identifier from `warming_identifiers`. That's the whole
             reason the broadcast exists.
             """
    end
  end
end
