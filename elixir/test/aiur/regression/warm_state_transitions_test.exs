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

  describe "do_select must not crash on await_replay timeout" do
    @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)
    @session_writer_source Path.expand(
                             "../../../lib/aiur/opencode/session_writer.ex",
                             __DIR__
                           )

    test "Slot.do_select handles {:error, :timeout} from await_replay without MatchError" do
      source = File.read!(@slot_source)

      # The bug was `:ok = SessionWriter.await_replay(...)`. The fix
      # must surface the timeout as a Slot.select return value (any
      # case/with against await_replay) so the warm Task's caller can
      # broadcast :attach_failed instead of being killed by a MatchError
      # exit. Without this, 4 of 5 slots wedge in :warming state
      # whenever SQLite contention slows replay past the 10 s budget.
      refute source =~ ~r/:ok\s*=\s*SessionWriter\.await_replay/,
             """
             slot.ex must NOT use `:ok = SessionWriter.await_replay(...)`.
             That pattern crashes the Slot worker with MatchError when
             replay times out under SQLite contention, which silently
             kills the AttachPool warm Task and leaves the agent stuck
             in ⏳ forever. Use `case`/`with` instead so the error
             propagates as a Slot.select return value.
             """

      assert source =~ ~r/case\s+SessionWriter\.await_replay/,
             """
             slot.ex must call `SessionWriter.await_replay/2` inside a
             `case` (or `with`) so the timeout branch returns
             `{:error, :timeout}` from `do_select/2` instead of
             crashing.
             """
    end

    test "SessionWriter wraps replay inserts in one SQLite transaction" do
      source = File.read!(@session_writer_source)

      replay_block =
        case Regex.run(~r/defp replay_history.*?\n  end\n/s, source) do
          [match | _] -> match
          _ -> raise "could not extract replay_history"
        end

      assert replay_block =~ ~r/Db\.with_transaction/,
             """
             SessionWriter.replay_history must batch its inserts inside
             a single `Db.with_transaction` call. Without this, every
             individual insert opens its own SQLite connection and
             contends for the write lock — N concurrent writers with
             ~100 inserts each blow past the 10 s await_replay timeout
             under any real concurrency.
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
