defmodule Aiur.Orchestrator.AgentTeardownTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{AgentTeardown, State}

  test "teardown helpers tolerate absent process identifiers" do
    assert AgentTeardown.terminate_task(nil) == :ok
  end

  test "kill_repl_session_os_only does not kill the repl pane" do
    entry = %{repl_pane_id: "%42", repl_os_pid: nil, headless_os_pid: nil}
    assert AgentTeardown.kill_repl_session_os_only(entry) == :ok
  end

  describe "deactivate_running_issue/2" do
    test "transitions entry to :deactivated and keeps it in running" do
      entry = working_entry("730")
      state = %State{running: %{"issue-730" => entry}}

      new_state = AgentTeardown.deactivate_running_issue(state, "issue-730")

      assert %{control: %{status: :deactivated}, pid: nil, ref: nil} =
               new_state.running["issue-730"]
    end

    test "does not kill the repl_pane_id — pane stays open for inspection" do
      entry = working_entry("730") |> Map.put(:repl_pane_id, "%42")
      state = %State{running: %{"issue-730" => entry}}

      new_state = AgentTeardown.deactivate_running_issue(state, "issue-730")

      assert new_state.running["issue-730"].repl_pane_id == "%42"
    end

    test "evicts prior deactivated entries so sequential completions do not exhaust slots" do
      # Three agents all reach human-review. Slots are claimed while entries
      # remain in state.running. Without the reaper, three completions would
      # fill state.running with three deactivated entries and exhaust the pool.
      entry_a = working_entry("1") |> Map.put(:control, %{status: :deactivated})
      entry_b = working_entry("2") |> Map.put(:control, %{status: :deactivated})
      entry_c = working_entry("3")

      state = %State{
        running: %{
          "issue-1" => entry_a,
          "issue-2" => entry_b,
          "issue-3" => entry_c
        }
      }

      # Deactivating the third agent should evict the two prior deactivated entries
      new_state = AgentTeardown.deactivate_running_issue(state, "issue-3")

      refute Map.has_key?(new_state.running, "issue-1")
      refute Map.has_key?(new_state.running, "issue-2")
      assert %{control: %{status: :deactivated}} = new_state.running["issue-3"]
    end

    test "evicted prior deactivated entries are also removed from state.claimed" do
      # Evicted entries left in state.claimed permanently block rework dispatch:
      # dispatch_policy checks !MapSet.member?(claimed, issue.id) and the normal
      # terminate_running_issue cleanup path never fires for evicted entries.
      entry_a = working_entry("1") |> Map.put(:control, %{status: :deactivated})
      entry_b = working_entry("2")

      state = %State{
        running: %{"issue-1" => entry_a, "issue-2" => entry_b},
        claimed: MapSet.new(["issue-1", "issue-2"])
      }

      new_state = AgentTeardown.deactivate_running_issue(state, "issue-2")

      refute Map.has_key?(new_state.running, "issue-1")
      refute MapSet.member?(new_state.claimed, "issue-1")
      assert MapSet.member?(new_state.claimed, "issue-2")
    end

    test "is idempotent on already-deactivated entry" do
      entry = working_entry("730") |> Map.put(:control, %{status: :deactivated})
      state = %State{running: %{"issue-730" => entry}}

      new_state = AgentTeardown.deactivate_running_issue(state, "issue-730")
      assert new_state == state
    end
  end

  defp working_entry(identifier) do
    %{
      identifier: identifier,
      control: %{status: :working},
      pid: nil,
      ref: nil,
      started_at: nil,
      issue: %Issue{id: "issue-#{identifier}", identifier: identifier}
    }
  end
end
