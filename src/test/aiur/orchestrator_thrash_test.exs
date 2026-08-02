defmodule Aiur.OrchestratorThrashTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher

  # Defaults come from the Agent schema: 6 restarts per 60s window.
  @issue_id "issue-thrash"
  @window_ms 60 * 1_000

  defp run(state, now_ms), do: Dispatcher.check_thrash_budget(state, @issue_id, now_ms)

  describe "lifetime dispatch budget" do
    test "disabled by default: lapsed windows reset forever (today's behavior)" do
      # This is how #1091 reached 85 cold dispatches: the per-window counter
      # resets on every lapsed window, so a structurally-churning ticket is
      # never circuit-broken. Locked here so the default stays a no-op.
      state =
        Enum.reduce(1..30, %Orchestrator.State{}, fn i, state ->
          assert {:ok, state} = run(state, i * (@window_ms + 1))
          state
        end)

      assert {:ok, _state} = run(state, 31 * (@window_ms + 1))
    end
  end

  describe "codex thrash budget" do
    test "allows up to the per-window max, then trips" do
      # Six dispatches inside one window stay healthy; the seventh trips.
      state =
        Enum.reduce(1..6, %Orchestrator.State{}, fn _i, state ->
          assert {:ok, state} = run(state, 0)
          state
        end)

      assert {:trip, _state} = run(state, 0)
    end

    test "a lapsed window resets the counter" do
      state =
        Enum.reduce(1..6, %Orchestrator.State{}, fn _i, state ->
          {:ok, state} = run(state, 0)
          state
        end)

      assert {:trip, state} = run(state, 0)

      # Once the window elapses the issue gets a fresh budget.
      assert {:ok, state} = run(state, @window_ms + 1)
      assert get_in(state.dispatch_recovery.codex_thrash_budget, [@issue_id, :count]) == 1
    end

    test "counts accumulate only within the active window" do
      assert {:ok, state} = run(%Orchestrator.State{}, 0)
      assert {:ok, state} = run(state, @window_ms - 1)
      assert get_in(state.dispatch_recovery.codex_thrash_budget, [@issue_id, :count]) == 2
    end
  end
end
