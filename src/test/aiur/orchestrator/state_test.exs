defmodule Aiur.Orchestrator.StateTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.State

  describe "running entry predicates" do
    test "classify entries by control status" do
      assert State.active_running_entry?(%{control: %{status: :working}})
      refute State.active_running_entry?(%{control: %{status: :paused}})
      refute State.active_running_entry?(%{control: %{status: :deactivated}})

      assert State.paused_running_entry?(%{control: %{status: :paused}})
      assert State.sleeping_running_entry?(%{control: %{status: :sleeping}})
      assert State.deactivated_running_entry?(%{control: %{status: :deactivated}})
    end

    test "count active and paused running entries" do
      running = %{
        "active" => %{control: %{status: :working}},
        "sleeping" => %{control: %{status: :sleeping}},
        "paused" => %{control: %{status: :paused}},
        "deactivated" => %{control: %{status: :deactivated}}
      }

      assert State.active_running_count(running) == 2
      assert State.paused_running_count(running) == 1
      assert State.active_running_count(:not_a_map) == 0
      assert State.paused_running_count(:not_a_map) == 0
    end
  end

  describe "running lookup helpers" do
    test "find running entries and keys by identifiers, pane ids, and refs" do
      ref = make_ref()

      running = %{
        "issue-1" => %{identifier: 42, repl_pane_id: "%1", ref: ref},
        "issue-2" => %{identifier: "repo#2", repl_pane_id: "%2", ref: make_ref()}
      }

      assert State.find_running_by_identifier(running, "42") == Map.fetch!(running, "issue-1")
      assert State.find_running_key_by_identifier(running, "42") == "issue-1"
      assert State.find_running_by_repl_pane_id(running, "%2") == Map.fetch!(running, "issue-2")
      assert State.find_issue_id_for_ref(running, ref) == "issue-1"
    end

    test "pop_running_entry returns the entry and state without it" do
      state = %State{running: %{"issue-1" => %{identifier: "repo#1"}}}

      assert {%{identifier: "repo#1"}, %State{running: %{}}} =
               State.pop_running_entry(state, "issue-1")
    end
  end

  describe "small value helpers" do
    test "maybe_put_runtime_value leaves nil values out" do
      assert State.maybe_put_runtime_value(%{a: 1}, :b, nil) == %{a: 1}
      assert State.maybe_put_runtime_value(%{a: 1}, :b, 2) == %{a: 1, b: 2}
    end

    test "issue_tag returns the first agent label" do
      issue = %Issue{labels: ["bug", "agent:todo", "agent:rework"]}

      assert State.issue_tag(issue) == "agent:todo"
      assert State.issue_tag(%{}) == nil
    end
  end

  describe "pause runtime clock" do
    test "stamps paused_at on working to paused and shifts started_at on resume" do
      started_at = ~U[2026-01-01 00:00:00Z]
      paused_at = ~U[2026-01-01 00:01:00Z]
      resumed_at = ~U[2026-01-01 00:03:00Z]

      paused = State.apply_pause_runtime_clock(%{started_at: started_at}, :working, :paused, paused_at)
      assert paused.paused_at == paused_at

      resumed = State.apply_pause_runtime_clock(paused, :paused, :working, resumed_at)
      assert resumed.paused_at == nil
      assert resumed.started_at == ~U[2026-01-01 00:02:00Z]
    end

    test "duration-capped pause only clears paused_at and does not credit started_at" do
      entry = %{
        started_at: ~U[2026-01-01 00:00:00Z],
        paused_at: ~U[2026-01-01 00:01:00Z],
        paused_reason: :max_agent_duration
      }

      assert %{started_at: ~U[2026-01-01 00:00:00Z], paused_at: nil} =
               State.shift_started_at_by_pause(entry, ~U[2026-01-01 00:03:00Z])
    end

    test "ordinary pause shifts started_at by the paused interval" do
      entry = %{
        started_at: ~U[2026-01-01 00:00:00Z],
        paused_at: ~U[2026-01-01 00:01:00Z]
      }

      assert %{started_at: ~U[2026-01-01 00:02:00Z], paused_at: nil} =
               State.shift_started_at_by_pause(entry, ~U[2026-01-01 00:03:00Z])
    end

    test "effective runtime freezes at paused_at" do
      entry = %{
        started_at: ~U[2026-01-01 00:00:00Z],
        paused_at: ~U[2026-01-01 00:01:30Z]
      }

      assert State.effective_runtime_seconds(entry, ~U[2026-01-01 00:10:00Z]) == 90
    end
  end
end
