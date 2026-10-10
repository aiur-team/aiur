defmodule Aiur.Orchestrator.Deactivate.SleepStateTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.Slots

  describe "Aiur.AgentEvents.state_emoji/1" do
    test ":deactivated maps to the 🏁 glyph" do
      assert Aiur.AgentEvents.state_emoji(:deactivated) == "🏁"
      assert Aiur.AgentEvents.state_emoji("deactivated") == "🏁"
    end

    test ":done still maps to 🏁 (existing semantic preserved)" do
      assert Aiur.AgentEvents.state_emoji(:done) == "🏁"
      assert Aiur.AgentEvents.state_emoji("done") == "🏁"
    end

    test ":sleeping maps to the 💤 glyph (idle stream-close)" do
      assert Aiur.AgentEvents.state_emoji(:sleeping) == "💤"
      assert Aiur.AgentEvents.state_emoji("sleeping") == "💤"
    end
  end

  describe "mark_sleeping flips control.status to :sleeping on idle stream-close" do
    test "a :working entry transitions to :sleeping" do
      issue_id = "issue-sleep-1"
      identifier = "SLEEP-1"

      state = sleeping_state(issue_id, identifier, :working)

      next = PushRouting.maybe_mark_sleeping(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :sleeping
    end

    test "a :sleeping entry holds its slot (does not free capacity)" do
      issue_id = "issue-sleep-slot"
      identifier = "SLEEP-SLOT"

      state = sleeping_state(issue_id, identifier, :working)
      next = PushRouting.maybe_mark_sleeping(state, identifier)

      # :sleeping is neither :paused nor :deactivated, so it still counts
      # as an active slot-holder — the agent is mid-turn, just idle-streamed.
      assert Slots.slot_status(next).active == 1
    end

    test "no-op when the entry is :paused (don't override a more-specific state)" do
      issue_id = "issue-sleep-paused"
      identifier = "SLEEP-PAUSED"

      state = sleeping_state(issue_id, identifier, :paused)

      next = PushRouting.maybe_mark_sleeping(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "no-op when the entry is :deactivated (don't wake the dead)" do
      issue_id = "issue-sleep-deact"
      identifier = "SLEEP-DEACT"

      state = sleeping_state(issue_id, identifier, :deactivated)

      next = PushRouting.maybe_mark_sleeping(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when the identifier isn't running" do
      state = sleeping_state("issue-sleep-x", "SLEEP-X", :working)
      assert ^state = PushRouting.maybe_mark_sleeping(state, "UNKNOWN")
    end

    test "the next turn's :worker_control_state :working flips 💤 back to 🟢" do
      issue_id = "issue-sleep-wake"
      identifier = "SLEEP-WAKE"

      slept =
        sleeping_state(issue_id, identifier, :working)
        |> PushRouting.maybe_mark_sleeping(identifier)

      assert get_in(slept.running, [issue_id, :control, :status]) == :sleeping

      {:noreply, woke} =
        Orchestrator.handle_info({:worker_control_state, issue_id, :working}, slept)

      assert get_in(woke.running, [issue_id, :control, :status]) == :working
    end

    test "the {:mark_sleeping, identifier} cast clause flips :working to :sleeping" do
      issue_id = "issue-sleep-cast"
      identifier = "SLEEP-CAST"

      state = sleeping_state(issue_id, identifier, :working)

      {:noreply, next} =
        Orchestrator.handle_cast({:mark_sleeping, identifier}, state)

      assert get_in(next.running, [issue_id, :control, :status]) == :sleeping
    end

    defp sleeping_state(issue_id, identifier, status) do
      %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: status}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }
    end
  end
end
