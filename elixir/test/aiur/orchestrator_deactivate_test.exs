defmodule Aiur.OrchestratorDeactivateTest do
  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.Issue
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator

  describe "reconcile with nil / non-binary issue state (crash regression)" do
    # Live crash signature (from production logs):
    #   ** (FunctionClauseError) no function clause matching in
    #      Aiur.Orchestrator.active_issue_state?(nil, MapSet.new(...))
    #   ** (FunctionClauseError) no function clause matching in
    #      Aiur.Orchestrator.normalize_issue_state(nil)
    #
    # GitHub poll can return an Issue with state=nil whenever no
    # `agent:*` label is set. Each predicate guarded by
    # `when is_binary(state_name)` MUST also accept the non-binary
    # case or the entire orchestrator GenServer crashes on the next
    # reconcile/poll cycle.

    test "nil issue.state does not crash reconcile_issue_state cond" do
      issue_id = "issue-nil-state"
      issue_identifier = "NS-1"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      # State derives nil whenever no agent:* label is present on
      # the polled issue.
      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: nil,
        title: "label-less issue",
        description: "",
        labels: []
      }

      # Must NOT raise FunctionClauseError. State unchanged is fine —
      # the orchestrator just leaves the issue alone until a recognized
      # label appears.
      result = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert result == state
    end

    test "empty string issue.state also survives" do
      issue_id = "issue-empty-state"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "ES-1",
        state: "",
        title: "blank state",
        description: "",
        labels: []
      }

      result = Orchestrator.reconcile_issue_states_for_test([issue], state)
      assert result == state
    end
  end

  describe "reconcile on agent:human-review label" do
    test "human-review state keeps the running entry, kills the task, marks :deactivated" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-1"
      issue_identifier = "DA-1"
      workspace = Path.join(test_root, issue_identifier)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        File.mkdir_p!(workspace)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

        # Entry survives — this is the whole point of the deactivate path.
        assert Map.has_key?(updated_state.running, issue_id)
        assert MapSet.member?(updated_state.claimed, issue_id)

        # Codex task pid was killed (mirror terminate_running_issue's teardown).
        refute Process.alive?(agent_pid)

        # Entry shape: pid cleared, control.status flipped to :deactivated.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert is_nil(entry.pid)
        assert get_in(entry, [:control, :status]) == :deactivated

        # Workspace not cleaned up (deactivation is non-terminal).
        assert File.exists?(workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "human-review on an already-deactivated entry is a no-op" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-noop-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-2"
      issue_identifier = "DA-2"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

        # Same shape after the second observation — no spurious task kill,
        # no double-deactivate side effect.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert is_nil(entry.pid)
        assert get_in(entry, [:control, :status]) == :deactivated
      after
        File.rm_rf(test_root)
      end
    end

    test "terminate (terminal label) also broadcasts aiur_turn_done for every active chat stream" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-terminate-stream-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-terminate-stream"
      issue_identifier = "TS-1"
      turn_a = "t-term-a"
      turn_b = "t-term-b"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Same two-stream prewarm-race shape as the deactivate test.
        ActiveTurns.put(issue_identifier, turn_a)
        ActiveTurns.put(issue_identifier, turn_b)

        :ok = AgentPubSub.subscribe_agent(issue_identifier)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        # Terminal label → terminate_running_issue with cleanup_workspace=true
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "done",
          title: "merged",
          description: "",
          labels: []
        }

        _ = Orchestrator.reconcile_issue_states_for_test([issue], state)

        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_a, :terminal}, 500
        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_b, :terminal}, 500

        assert {:closed, :terminal} = ActiveTurns.lookup(issue_identifier, turn_a)
        assert {:closed, :terminal} = ActiveTurns.lookup(issue_identifier, turn_b)
      after
        File.rm_rf(test_root)
      end
    end

    test "deactivate broadcasts aiur_turn_done for every active chat-completion stream" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-stream-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-stream"
      issue_identifier = "DS-1"
      turn_a = "t-stream-a"
      turn_b = "t-stream-b"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Simulate two pre-warmed chat completion SSE streams for the
        # same identifier (the real-world cause of the duplicate
        # "No turn activity" messages).
        ActiveTurns.put(issue_identifier, turn_a)
        ActiveTurns.put(issue_identifier, turn_b)

        :ok = AgentPubSub.subscribe_agent(issue_identifier)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        _ = Orchestrator.reconcile_issue_states_for_test([issue], state)

        # Both streams receive the close broadcast.
        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_a, :deactivated}, 500
        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_b, :deactivated}, 500

        # The ActiveTurns entries are marked closed so any late SSE
        # subscribe finalizes with the same reason instead of waiting
        # on the broadcast it missed.
        assert {:closed, :deactivated} = ActiveTurns.lookup(issue_identifier, turn_a)
        assert {:closed, :deactivated} = ActiveTurns.lookup(issue_identifier, turn_b)
      after
        File.rm_rf(test_root)
      end
    end

    test "terminal label still terminates and cleans workspace (not intercepted by deactivate)" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-terminal-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-3"
      issue_identifier = "DA-3"
      workspace = Path.join(test_root, issue_identifier)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        File.mkdir_p!(workspace)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        # Terminal state — the deactivate branch must NOT intercept.
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "done",
          title: "Closed",
          description: "",
          labels: []
        }

        updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

        refute Map.has_key?(updated_state.running, issue_id)
        refute MapSet.member?(updated_state.claimed, issue_id)
        refute Process.alive?(agent_pid)
        refute File.exists?(workspace)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "Aiur.AgentEvents.state_emoji/1" do
    test ":deactivated maps to the 🏁 glyph" do
      assert Aiur.AgentEvents.state_emoji(:deactivated) == "🏁"
      assert Aiur.AgentEvents.state_emoji("deactivated") == "🏁"
    end

    test ":done still maps to 🏁 (existing semantic preserved)" do
      assert Aiur.AgentEvents.state_emoji(:done) == "🏁"
      assert Aiur.AgentEvents.state_emoji("done") == "🏁"
    end
  end

  describe "slot counting on the public status snapshot" do
    test "deactivated entries do not consume a slot in the (N/M) counter" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-slot-counting-#{System.unique_integer([:positive])}"
        )

      issue_working = "issue-slot-working"
      issue_paused = "issue-slot-paused"
      issue_deactivated = "issue-slot-deactivated"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        running = %{
          issue_working => %{
            pid: self(),
            ref: nil,
            identifier: "SLOT-1",
            issue: %Issue{id: issue_working, state: "in-progress", identifier: "SLOT-1"},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          },
          issue_paused => %{
            pid: self(),
            ref: nil,
            identifier: "SLOT-2",
            issue: %Issue{id: issue_paused, state: "in-progress", identifier: "SLOT-2"},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          },
          issue_deactivated => %{
            pid: nil,
            ref: nil,
            identifier: "SLOT-3",
            issue: %Issue{id: issue_deactivated, state: "human-review", identifier: "SLOT-3"},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        }

        state = %Orchestrator.State{
          running: running,
          claimed: MapSet.new(Map.keys(running)),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        # `active` counts entries holding a slot. After U3, that's
        # :working only — :paused holds a slot too today (existing
        # behaviour, exposed as `paused`), and :deactivated holds NONE.
        status = Orchestrator.slot_status_for_test(state)

        assert status.active == 1
        assert status.paused == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "all-:deactivated running map frees every slot" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-slot-all-deact-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        running =
          for n <- 1..3, into: %{} do
            id = "issue-deact-all-#{n}"

            {id,
             %{
               pid: nil,
               ref: nil,
               identifier: "ALL-#{n}",
               issue: %Issue{id: id, state: "human-review", identifier: "ALL-#{n}"},
               started_at: DateTime.utc_now(),
               control: %{status: :deactivated}
             }}
          end

        state = %Orchestrator.State{
          running: running,
          claimed: MapSet.new(Map.keys(running)),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        status = Orchestrator.slot_status_for_test(state)

        assert status.active == 0
        assert status.paused == 0
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "label-flip back to active reactivates a :deactivated entry" do
    test "human-review → in-progress on a :deactivated entry routes through reactivate_issue" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-relabel-active-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-relabel-1"
      issue_identifier = "RL-1"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Start with a :deactivated entry (the post-U2 shape).
        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        # Label flips back to in-progress (e.g., operator requested rework).
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "in-progress",
          title: "Rework requested",
          description: "",
          labels: []
        }

        updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

        # The entry's stored issue is refreshed to the new state.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.issue.state == "in-progress"

        # The entry is no longer :deactivated — reactivate_issue cleared
        # the status (may or may not have a pid yet depending on the
        # dispatcher's worker-host check, but it should NOT still be
        # `:deactivated`).
        refute get_in(entry, [:control, :status]) == :deactivated
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "PR review-comment firehose reactivation (subscriber wiring)" do
    test "topic parser extracts the issue number from a valid topic" do
      # Helper covers the regex shape used by the orchestrator's
      # handle_info({:event, ...}) clause. Anchors guard against
      # accidental match drift if other ticket subtopics are added.
      assert {:ok, "140"} =
               Orchestrator.parse_pr_review_comment_topic_for_test("ticket.140.pr.review_comment")
    end

    test "topic parser rejects unrelated topics" do
      for unrelated <- [
            "ticket.140.issue.commented",
            "ticket.140.pr.opened",
            "ticket.140.agent.progress",
            "system.repo.branch.push"
          ] do
        assert :nomatch = Orchestrator.parse_pr_review_comment_topic_for_test(unrelated)
      end
    end
  end
end
