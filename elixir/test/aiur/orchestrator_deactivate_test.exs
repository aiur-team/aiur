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

  describe "pause-request topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid agent.pause.request topic" do
      assert {:ok, "100"} =
               Orchestrator.parse_pause_request_topic_for_test("ticket.100.agent.pause.request")

      assert {:ok, "ABC-42"} =
               Orchestrator.parse_pause_request_topic_for_test("ticket.ABC-42.agent.pause.request")
    end

    test "rejects unrelated topics" do
      for unrelated <- [
            "ticket.100.agent.pause",
            "ticket.100.agent.pause.requested",
            "ticket.100.pr.review_comment",
            "system.main.branch.push"
          ] do
        assert :nomatch = Orchestrator.parse_pause_request_topic_for_test(unrelated)
      end
    end
  end

  describe "agent.pause.request flips control.status to :paused" do
    test "running entry transitions from :working → :paused" do
      issue_id = "issue-pause-1"
      identifier = "PAUSE-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_pause_request_for_test(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "no-op when entry is already paused" do
      issue_id = "issue-pause-2"
      identifier = "PAUSE-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = Orchestrator.apply_pause_request_for_test(state, identifier)
    end

    test "no-op when entry is :deactivated (don't bring back from the dead)" do
      issue_id = "issue-pause-3"
      identifier = "PAUSE-3"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_pause_request_for_test(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when identifier isn't running" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = Orchestrator.apply_pause_request_for_test(state, "UNKNOWN")
    end
  end

  describe "stall watchdog skips paused / deactivated entries" do
    test "paused entry with stale last_codex_timestamp is NOT restarted" do
      issue_id = "issue-stall-paused"
      identifier = "STALL-P"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: spawn_link(fn -> Process.sleep(:infinity) end),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      # 1ms timeout would trip on any entry whose elapsed > 1ms — but
      # the paused short-circuit must skip it BEFORE elapsed is computed.
      next = Orchestrator.apply_stall_check_for_test(state, 1)
      assert Map.has_key?(next.running, issue_id), "paused entry must not be restarted"
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert next.retry_attempts == %{}, "no retry should be scheduled"
    end

    test "deactivated entry with stale last_codex_timestamp is NOT restarted" do
      issue_id = "issue-stall-deact"
      identifier = "STALL-D"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_stall_check_for_test(state, 1)
      assert Map.has_key?(next.running, issue_id)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
      assert next.retry_attempts == %{}
    end

    test "actively-working entry with stale last_codex_timestamp IS restarted" do
      issue_id = "issue-stall-working"
      identifier = "STALL-W"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_stall_check_for_test(state, 1)
      refute Map.has_key?(next.running, issue_id), "working+stale entry must be restarted"

      assert %{identifier: ^identifier, error: "stalled" <> _} =
               Map.get(next.retry_attempts, issue_id)
    end
  end

  describe "ticket.<blocker>.branch.push auto-resumes paused blockees" do
    setup do
      identifier = "BLOCKEE-#{System.unique_integer([:positive])}"
      :ok = Aiur.Events.SubscriptionStore.attach(identifier)
      on_exit(fn -> :ok = Aiur.Events.SubscriptionStore.stop(identifier) end)

      fake_pid = spawn_link(fn -> fake_agent_loop() end)

      %{identifier: identifier, fake_pid: fake_pid}
    end

    defp fake_agent_loop do
      receive do
        _ -> fake_agent_loop()
      end
    end

    test "paused blockee subscribed to ticket.99.branch.push flips to :working", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok =
        Aiur.Events.SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.branch.push",
          "blocker:auto"
        )

      issue_id = "issue-blockee-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_branch_push_for_test(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "running blockee (not paused) is unchanged", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok =
        Aiur.Events.SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.branch.push",
          "blocker:auto"
        )

      issue_id = "issue-blockee-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_branch_push_for_test(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "paused blockee NOT subscribed to this blocker stays paused", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      # Subscribe to a DIFFERENT blocker's push; the 99 push should be
      # treated as not relevant to this entry.
      :ok =
        Aiur.Events.SubscriptionStore.add_subscription(
          identifier,
          "ticket.42.branch.push",
          "blocker:auto"
        )

      issue_id = "issue-blockee-3"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_branch_push_for_test(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "blocker's own entry is never resumed against its own push", %{
      identifier: blocker_identifier,
      fake_pid: fake_pid
    } do
      # An agent could theoretically be subscribed to its own push topic
      # (via aiur_subscribe). Defensive: don't resume the publisher itself.
      :ok =
        Aiur.Events.SubscriptionStore.add_subscription(
          blocker_identifier,
          "ticket.#{blocker_identifier}.branch.push",
          "manual:agent"
        )

      issue_id = "issue-blocker-self"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: blocker_identifier,
            issue: %Issue{
              id: issue_id,
              state: "in-progress",
              identifier: blocker_identifier
            },
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_branch_push_for_test(state, blocker_identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end
  end

  describe "branch-push topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid ticket.<id>.branch.push topic" do
      assert {:ok, "99"} =
               Orchestrator.parse_branch_push_topic_for_test("ticket.99.branch.push")
    end

    test "rejects system-branch pushes (not ticket-scoped)" do
      assert :nomatch =
               Orchestrator.parse_branch_push_topic_for_test("system.main.branch.push")
    end

    test "rejects nearby topics" do
      for unrelated <- [
            "ticket.99.branch.force-push",
            "ticket.99.pr.opened",
            "ticket.99.agent.pause.request"
          ] do
        assert :nomatch = Orchestrator.parse_branch_push_topic_for_test(unrelated)
      end
    end
  end
end
