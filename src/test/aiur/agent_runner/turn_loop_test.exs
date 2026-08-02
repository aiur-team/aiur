defmodule Aiur.AgentRunner.TurnLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnLoop

  # A briefly overloaded orchestrator queue GenServer answers the restore RPC
  # with `{:error, :unavailable}` / `:timeout` for a few calls before it
  # recovers. `calls` proves how many restore attempts the boundary made.
  defmodule FlakyRestoreOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         unavailable_left: Keyword.fetch!(opts, :unavailable),
         reason: Keyword.get(opts, :reason, :unavailable),
         calls: 0
       }}
    end

    @impl true
    def handle_call({:restore_delivered_queue_items, _identifier}, _from, state) do
      state = %{state | calls: state.calls + 1}

      if state.unavailable_left > 0 do
        {:reply, {:error, state.reason}, %{state | unavailable_left: state.unavailable_left - 1}}
      else
        {:reply, :ok, state}
      end
    end

    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}
  end

  # #1238: the one confirmed restore-and-replace boundary shared by the
  # primary-turn (`run_turns`) and queue-drain (`run_recorded_queue_item_turn`)
  # seams. It must confirm the durable restore before reporting a clean
  # replacement exit, and must never silently strand the delivered item.
  describe "confirm_restore_for_replacement/4" do
    setup do
      %{issue: %Aiur.Issue{id: "gid-1238", identifier: "TL-1238"}}
    end

    test "retries a transient unavailable restore, then returns the recoverable error", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 2)

      assert TurnLoop.confirm_restore_for_replacement(
               orch,
               issue,
               [restore_confirm_backoff_ms: 0],
               {:error, :port_closed}
             ) == {:error, :port_closed}

      # Two unavailable answers were retried through; the third confirmed.
      assert GenServer.call(orch, :calls) == 3
    end

    test "retries a transient timeout restore the same way", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 1, reason: :timeout)

      assert TurnLoop.confirm_restore_for_replacement(
               orch,
               issue,
               [restore_confirm_backoff_ms: 0],
               {:error, {:turn_interrupt_failed, :port_closed}}
             ) == {:error, {:turn_interrupt_failed, :port_closed}}

      assert GenServer.call(orch, :calls) == 2
    end

    test "refuses to report clean recovery when the restore never confirms", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 99)

      assert TurnLoop.confirm_restore_for_replacement(
               orch,
               issue,
               [restore_confirm_backoff_ms: 0, restore_confirm_attempts: 3],
               {:error, :port_closed}
             ) == {:error, {:queue_restore_unconfirmed, :unavailable}}

      # Bounded: it stops at the attempt cap instead of spinning forever.
      assert GenServer.call(orch, :calls) == 3
    end

    test "an immediately available restore confirms in a single call", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 0)

      assert TurnLoop.confirm_restore_delivered(orch, issue, restore_confirm_backoff_ms: 0) == :ok
      assert GenServer.call(orch, :calls) == 1
    end
  end

  describe "turn_done_reason/1" do
    test "maps coding-agent turn results to stream close reasons" do
      assert TurnLoop.turn_done_reason({:ok, %{}}) == :done
      assert TurnLoop.turn_done_reason({:paused, %{}}) == :input_required
      assert TurnLoop.turn_done_reason({:error, :boom}) == {:failed, :boom}
      assert TurnLoop.turn_done_reason(:other) == :done
    end
  end

  describe "max_turns_display/1" do
    test "renders nil as infinity and integers as strings" do
      assert TurnLoop.max_turns_display(nil) == "∞"
      assert TurnLoop.max_turns_display(3) == "3"
    end
  end

  describe "return_completed/2" do
    test "returns the final boundary for publication after outer cleanup" do
      issue = %Aiur.Issue{id: "issue-completed"}

      assert {:completed, ^issue} =
               TurnLoop.return_completed(%{codex_update_recipient: self()}, issue)

      refute_receive {:worker_control_state, "issue-completed", :completed}
    end
  end

  describe "continue_after_resume/2" do
    test "returns a completed boundary when max turns were already reached" do
      issue = %Aiur.Issue{id: "issue-max", identifier: "MT-MAX", state: "In Progress"}
      refreshed = %{issue | state: "In Progress"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-max"] -> {:ok, [refreshed]} end,
        max_turns: 1,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end

    test "returns a completed boundary when the refreshed issue is inactive" do
      issue = %Aiur.Issue{id: "issue-done", identifier: "MT-DONE", state: "In Progress"}
      refreshed = %{issue | state: "Done"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-done"] -> {:ok, [refreshed]} end,
        max_turns: 3,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end
  end
end
