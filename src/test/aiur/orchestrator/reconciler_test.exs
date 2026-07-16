defmodule Aiur.Orchestrator.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.TrackerIdentity

  describe "reconcile_running_issue_states/4" do
    test "returns state unchanged for empty list" do
      state = %State{running: %{"issue-1" => %{pid: self()}}}
      active = MapSet.new(["todo"])
      terminal = MapSet.new(["done"])

      assert Reconciler.reconcile_running_issue_states([], state, active, terminal) == state
    end
  end

  describe "reconcile_issue_state/4" do
    test "returns state unchanged for non-Issue first arg" do
      state = %State{}
      active = MapSet.new(["todo"])
      terminal = MapSet.new(["done"])

      assert Reconciler.reconcile_issue_state(:not_an_issue, state, active, terminal) == state
      assert Reconciler.reconcile_issue_state(nil, state, active, terminal) == state
      assert Reconciler.reconcile_issue_state(%{}, state, active, terminal) == state
    end

    test "records a terminal lifecycle before removing its running entry" do
      parent = self()
      identity = tracker_identity("I-terminal")
      issue = %Issue{id: "issue-terminal", identifier: "I-terminal", state: "done", tracker_identity: identity}

      assert %State{} =
               Reconciler.reconcile_issue_state(
                 issue,
                 %State{running: %{"issue-terminal" => %{issue: issue}}},
                 MapSet.new(["in-progress"]),
                 MapSet.new(["done"]),
                 fn observed_identity, lifecycle ->
                   send(parent, {observed_identity, lifecycle})
                   :ok
                 end
               )

      assert_received {^identity, :completed}
    end

    test "records cancellation and replacement lifecycle observations" do
      parent = self()
      identity = tracker_identity("I-cancelled")

      cancelled = %Issue{
        id: "issue-cancelled",
        identifier: "I-cancelled",
        state: "cancelled",
        tracker_identity: identity
      }

      Reconciler.reconcile_issue_state(
        cancelled,
        %State{},
        MapSet.new(["in-progress"]),
        MapSet.new(["cancelled"]),
        fn observed_identity, lifecycle ->
          send(parent, {observed_identity, lifecycle})
          :ok
        end
      )

      assert_received {^identity, :cancelled}

      replacement = %Issue{
        id: "issue-replaced",
        identifier: "I-replaced",
        state: "replaced",
        tracker_identity: identity,
        assigned_to_worker: false
      }

      Reconciler.reconcile_issue_state(
        replacement,
        %State{},
        MapSet.new(["in-progress"]),
        MapSet.new(),
        fn observed_identity, lifecycle ->
          send(parent, {observed_identity, lifecycle})
          :ok
        end
      )

      assert_received {^identity, :replaced}
    end
  end

  defp drain_resume_agent_messages(acc \\ []) do
    receive do
      {:resume_agent, _request_id} -> drain_resume_agent_messages([:resume | acc])
    after
      0 -> acc
    end
  end

  defp tracker_identity(provider_id) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: provider_id,
      identifier: "42",
      reason: nil
    }
  end

  describe "refresh_running_issue_state/2" do
    test "updates the stored issue in the running entry" do
      old_issue = %Issue{id: "issue-1", identifier: "repo#1", title: "old", state: "todo"}
      new_issue = %Issue{id: "issue-1", identifier: "repo#1", title: "new", state: "in-progress"}

      state = %State{
        running: %{"issue-1" => %{pid: self(), issue: old_issue}}
      }

      result = Reconciler.refresh_running_issue_state(state, new_issue)
      assert get_in(result.running, ["issue-1", :issue]) == new_issue
    end

    test "returns state unchanged when issue_id is not running" do
      issue = %Issue{id: "issue-x", identifier: "repo#x", title: "t", state: "todo"}
      state = %State{running: %{}}

      assert Reconciler.refresh_running_issue_state(state, issue) == state
    end
  end

  describe "maybe_reactivate_or_refresh/2 before_run_failure recovery" do
    test "resumes a before_run_failure pause on an active-state issue" do
      issue = %Issue{id: "issue-brf", identifier: "issue-brf", state: "rework"}

      entry = %{
        pid: self(),
        identifier: "issue-brf",
        issue: issue,
        control: %{status: :paused},
        paused_reason: :before_run_failure
      }

      state = %State{running: %{"issue-brf" => entry}, max_concurrent_agents: 10}

      result = Reconciler.maybe_reactivate_or_refresh(state, issue)

      # The parked agent is blocked in AgentRunner.wait_for_before_run_resume/3;
      # a transient hook failure must self-heal by delivering the resume signal
      # to its live pid, not sit paused forever.
      assert_received {:resume_agent, _request_id}
      assert get_in(result.running, ["issue-brf", :control, :status]) == :working
    end

    test "auto-recovery of a persistently-failing before_run hook is bounded" do
      issue = %Issue{id: "issue-brf-loop", identifier: "issue-brf-loop", state: "rework"}

      entry = %{
        pid: self(),
        identifier: "issue-brf-loop",
        issue: issue,
        control: %{status: :paused},
        paused_reason: :before_run_failure
      }

      state = %State{running: %{"issue-brf-loop" => entry}, max_concurrent_agents: 10}

      polls = 20

      final_state =
        Enum.reduce(1..polls, state, fn _poll, acc ->
          acc = Reconciler.maybe_reactivate_or_refresh(acc, issue)
          current = acc.running["issue-brf-loop"]

          # Simulate the agent re-running the hook, failing again, and re-parking
          # itself — but only on the polls that actually resumed it.
          if get_in(current, [:control, :status]) == :working do
            reparked =
              current
              |> put_in([:control, :status], :paused)
              |> Map.put(:paused_reason, :before_run_failure)

            %{acc | running: Map.put(acc.running, "issue-brf-loop", reparked)}
          else
            acc
          end
        end)

      resume_signals = drain_resume_agent_messages()

      assert resume_signals != [],
             "a transient failure must get at least one automatic recovery attempt"

      # A persistent merge conflict must not resume on every poll forever; the
      # reconciler gives up well before the polling loop would.
      assert length(resume_signals) < polls,
             "before_run_failure recovery must be bounded, not retry every poll forever"

      assert get_in(final_state.running["issue-brf-loop"], [:control, :status]) == :paused
    end
  end

  describe "reconcile_missing_running_issue_ids/3" do
    test "returns state unchanged when all requested ids are visible" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "t", state: "todo"}

      state = %State{
        running: %{"issue-1" => %{pid: self(), identifier: "repo#1"}},
        claimed: MapSet.new(["issue-1"])
      }

      assert Reconciler.reconcile_missing_running_issue_ids(state, ["issue-1"], [issue]) == state
    end

    test "returns state unchanged for non-State first arg" do
      assert Reconciler.reconcile_missing_running_issue_ids(:not_state, [], []) == :not_state
    end

    test "ignores non-Issue entries in the issues list" do
      state = %State{
        running: %{"issue-1" => %{pid: self(), identifier: "repo#1"}},
        claimed: MapSet.new(["issue-1"])
      }

      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "t", state: "todo"}
      issues = [issue, :bad_entry, nil]

      assert Reconciler.reconcile_missing_running_issue_ids(state, ["issue-1"], issues) == state
    end
  end
end
