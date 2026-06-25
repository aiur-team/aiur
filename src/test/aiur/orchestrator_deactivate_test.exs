defmodule Aiur.OrchestratorDeactivateTest do
  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.AgentQueueStore
  alias Aiur.Events.{Exchange, SubscriptionStore}
  alias Aiur.Issue
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  defmodule ErrorLinearClient do
    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :tracker_down}

    def graphql(query, %{"issueId" => _issue_id, "stateName" => "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{issueId: _issue_id, stateName: "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{"issueId" => _issue_id, "stateId" => "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

    def graphql(query, %{issueId: _issue_id, stateId: "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end
  end

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
      # Linear default config namespaces workspaces under <root>/<project_slug>/.
      workspace = Path.join([test_root, "project", issue_identifier])

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

      next = Orchestrator.apply_mark_sleeping_for_test(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :sleeping
    end

    test "a :sleeping entry holds its slot (does not free capacity)" do
      issue_id = "issue-sleep-slot"
      identifier = "SLEEP-SLOT"

      state = sleeping_state(issue_id, identifier, :working)
      next = Orchestrator.apply_mark_sleeping_for_test(state, identifier)

      # :sleeping is neither :paused nor :deactivated, so it still counts
      # as an active slot-holder — the agent is mid-turn, just idle-streamed.
      assert Orchestrator.slot_status_for_test(next).active == 1
    end

    test "no-op when the entry is :paused (don't override a more-specific state)" do
      issue_id = "issue-sleep-paused"
      identifier = "SLEEP-PAUSED"

      state = sleeping_state(issue_id, identifier, :paused)

      next = Orchestrator.apply_mark_sleeping_for_test(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "no-op when the entry is :deactivated (don't wake the dead)" do
      issue_id = "issue-sleep-deact"
      identifier = "SLEEP-DEACT"

      state = sleeping_state(issue_id, identifier, :deactivated)

      next = Orchestrator.apply_mark_sleeping_for_test(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when the identifier isn't running" do
      state = sleeping_state("issue-sleep-x", "SLEEP-X", :working)
      assert ^state = Orchestrator.apply_mark_sleeping_for_test(state, "UNKNOWN")
    end

    test "the next turn's :worker_control_state :working flips 💤 back to 🟢" do
      issue_id = "issue-sleep-wake"
      identifier = "SLEEP-WAKE"

      slept =
        sleeping_state(issue_id, identifier, :working)
        |> Orchestrator.apply_mark_sleeping_for_test(identifier)

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

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "topic parser extracts the ticket number from a valid topic" do
      assert {:ok, "7"} =
               Orchestrator.parse_issue_commented_topic_for_test("ticket.7.issue.commented")
    end

    test "topic parser rejects unrelated topics" do
      for unrelated <- [
            "ticket.7.pr.review_comment",
            "ticket.7.issue.comment",
            "ticket.7.issue.commented.extra",
            "ticket.7.pr.opened",
            "system.repo.branch.push"
          ] do
        assert :nomatch = Orchestrator.parse_issue_commented_topic_for_test(unrelated)
      end
    end

    test "reactivates a :deactivated entry on ticket.<N>.issue.commented when refreshed state is active" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-1"
      # The firehose resolves PR-conversation comments back to the ticket
      # id before publishing, so the topic number is the agent identifier.
      issue_identifier = "7"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Rework requested",
            description: "",
            labels: []
          }
        ])

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

        {:noreply, next} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
            state
          )

        assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        refute get_in(entry, [:control, :status]) == :deactivated
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "reactivates a :deactivated entry on ticket.<N>.pr.review_comment when refreshed state is active" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-pr-review-comment-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-pr-review-comment-1"
      issue_identifier = "44"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Review comment requested rework",
            description: "",
            labels: []
          }
        ])

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

        {:noreply, next} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.pr.review_comment", author_trusted?: true}},
            state
          )

        assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        refute get_in(entry, [:control, :status]) == :deactivated
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate a human-review entry on ticket.<N>.issue.commented" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-human-review-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-hr"
      issue_identifier = "43"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "human-review",
            title: "Ready for human review",
            description: "",
            labels: []
          }
        ])

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

        {:noreply, next} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.issue.commented"}},
            state
          )

        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        File.rm_rf(test_root)
      end
    end

    test "review-pass PR comment stays human-review until successful merge marks issue done" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-review-pass-merge-#{System.unique_integer([:positive])}"
        )

      issue_id = "560"
      issue_identifier = "560"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())
        Application.put_env(:aiur, :memory_tracker_issues, [])

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

        {:noreply, after_comment} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.issue.commented",
               author_trusted?: true,
               comment: %{body: "[codex] Review passed for commit abc123"}
             }},
            state
          )

        refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 100
        assert get_in(after_comment.running[issue_id], [:control, :status]) == :deactivated

        {:noreply, after_review_comment} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.pr.review_comment",
               author_trusted?: true,
               comment: %{body: "[codex] Review passed for commit abc123"}
             }},
            after_comment
          )

        refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 100
        assert get_in(after_review_comment.running[issue_id], [:control, :status]) == :deactivated

        {:noreply, after_merge} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.pr.merged"}},
            after_review_comment
          )

        assert_receive {:memory_tracker_state_update, ^issue_id, "done"}
        refute Map.has_key?(after_merge.running, issue_id)
        refute MapSet.member?(after_merge.claimed, issue_id)
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate when refreshed issue is missing" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-missing-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-missing"
      issue_identifier = "45"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_issues, [])

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

        parent = self()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                state
              )
            )
          end)

        assert_receive {:noreply, next}
        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
        assert log =~ "issue_id=#{issue_id} issue_identifier=#{issue_identifier}"
        assert log =~ "reason=:missing"
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate when tracker refresh fails" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-refresh-error-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-refresh-error"
      issue_identifier = "46"
      previous_linear_client = Application.get_env(:aiur, :linear_client_module)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "linear",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :linear_client_module, ErrorLinearClient)
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
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        parent = self()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                state
              )
            )
          end)

        assert_receive {:noreply, next}
        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
        assert log =~ "issue_id=#{issue_id} issue_identifier=#{issue_identifier}"
        assert log =~ "reason=:tracker_down"
      after
        if previous_linear_client do
          Application.put_env(:aiur, :linear_client_module, previous_linear_client)
        else
          Application.delete_env(:aiur, :linear_client_module)
        end

        File.rm_rf(test_root)
      end
    end

    test "trusted comment for an idle issue transitions it to rework and queues the comment" do
      issue_id = "issue-issue-commented-2"
      issue_identifier = "7"
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :memory_tracker_recipient, self())

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 123,
          topic: "ticket.#{issue_identifier}.issue.commented",
          source: :github,
          author_trusted?: true,
          message: "please fix the PR",
          comment: %{"body" => "please fix the PR"}
        }

        assert {:noreply, next_state} =
                 Orchestrator.handle_info(
                   {:event, event},
                   state
                 )

        assert_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}
        refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 50

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(next_state.queue_store, issue_identifier)

        assert %{
                 subscribed_to: subscribed_to
               } = SubscriptionStore.snapshot(issue_identifier)

        topics = Enum.map(subscribed_to, & &1["topic"])
        assert "ticket.#{issue_identifier}.issue.commented" in topics
        assert "ticket.#{issue_identifier}.pr.review_comment" in topics
      after
        :ok = SubscriptionStore.stop(issue_identifier)

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end
      end
    end

    test "direct comment poll watches human-review issues without running entries" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{id: "57", identifier: "57", state: "human-review"}
      :ok = Exchange.subscribe("ticket.57.pr.review_comment")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/57/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: [%{"number" => 61}]}}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 5701,
                   "body" => "same-whale transfers should stay sequential",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        Orchestrator.poll_github_comments_for_test(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == "2026-06-24T11:59:59Z"

      assert_receive {:event,
                      %{
                        topic: "ticket.57.pr.review_comment",
                        source: :github,
                        message: "same-whale transfers should stay sequential"
                      }},
                     500
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll keeps running and human-review targets" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      human_review_issue = %Issue{id: "57", identifier: "57", state: "human-review"}
      :ok = Exchange.subscribe("ticket.42.issue.commented")
      :ok = Exchange.subscribe("ticket.57.pr.review_comment")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 4201,
                   "body" => "running target comment",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/issues/57/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") and String.contains?(url, "aiur%2F42") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") and String.contains?(url, "aiur%2F57") ->
            {:ok, %{status: 200, body: [%{"number" => 61}]}}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 5702,
                   "body" => "human-review target comment",
                   "updated_at" => "2026-06-24T12:02:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}
        end
      end

      state = %Orchestrator.State{
        running: %{
          "issue-42" => %{
            identifier: "42",
            issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
            control: %{status: :working}
          }
        },
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        Orchestrator.poll_github_comments_for_test(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review"] -> {:ok, [human_review_issue]} end
        )

      assert next.github_comments_since == "2026-06-24T12:01:59Z"
      assert_receive {:event, %{topic: "ticket.42.issue.commented", message: "running target comment"}}, 500

      assert_receive {:event, %{topic: "ticket.57.pr.review_comment", message: "human-review target comment"}},
                     500
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll preserves cursor when human-review target refresh fails" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      :ok = Exchange.subscribe("ticket.42.issue.commented")

      request_fun = fn %{url: url} ->
        send(parent, {:unexpected_comment_request, url})

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "id" => 4201,
               "body" => "running target comment",
               "updated_at" => "2026-06-24T12:00:00Z",
               "user" => %{"login" => "its-everdred"}
             }
           ]
         }}
      end

      state = %Orchestrator.State{
        running: %{
          "issue-42" => %{
            identifier: "42",
            issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
            control: %{status: :working}
          }
        },
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        Orchestrator.poll_github_comments_for_test(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review"] -> {:error, :tracker_down} end
        )

      assert next.github_comments_since == "2026-06-24T11:00:00Z"
      refute_receive {:unexpected_comment_request, _url}, 100
      refute_receive {:event, _event}, 100
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "leaves a :working entry untouched (no re-dispatch on comment)" do
      issue_id = "issue-issue-commented-3"
      issue_identifier = "7"
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        # A live (:working) agent already sees the comment via its own
        # subscription; the orchestrator must not re-dispatch or relabel it.
        assert {:noreply, ^state} =
                 Orchestrator.handle_info(
                   {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                   state
                 )

        refute_receive {:memory_tracker_state_update, _, _}, 50
      after
        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end
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

    test "stamps paused_at on the entry so the runtime clock freezes" do
      issue_id = "issue-pause-clock"
      identifier = "PAUSE-CLOCK"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = Orchestrator.apply_pause_request_for_test(state, identifier)
      entry = next.running[issue_id]

      assert entry.control.status == :paused

      assert %DateTime{} = entry.paused_at,
             "paused_at must be stamped so resume can thaw the clock and exclude the paused interval from running_seconds"
    end
  end

  describe "subscribe_for_declared_blocker/2 (called from agent_runner on declare)" do
    test "blockee gets ticket.<blocker>.branch.push subscription immediately" do
      blockee = "BSDB-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      topics = Enum.map(subs, fn entry -> entry["topic"] || entry[:topic] end)

      assert "ticket.#{blocker}.branch.push" in topics,
             "blockee must subscribe to blocker's branch.push so auto-resume can fire"
    end

    test "second call is idempotent (no duplicate subscriptions)" do
      blockee = "BSDB-idem-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-idem-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)
      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      push_subs =
        Enum.filter(subs, fn e ->
          (e["topic"] || e[:topic]) == "ticket.#{blocker}.branch.push"
        end)

      assert length(push_subs) == 1
    end

    test "accepts integer identifiers (the GitHub API path)" do
      blockee = "BSDB-int-#{System.unique_integer([:positive])}"
      blocker_int = System.unique_integer([:positive])

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(to_string(blocker_int))
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker_int)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)
      topics = Enum.map(subs, fn e -> e["topic"] || e[:topic] end)

      assert "ticket.#{blocker_int}.branch.push" in topics
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

    test "claude-hook activity refreshes liveness so an active RC-claude entry is NOT stall-restarted" do
      # An RC-claude agent works via lifecycle hooks, which never produce a
      # codex update — so `last_codex_timestamp` stays at `started_at` while
      # the agent is busy. A hook firing must refresh liveness so the stall
      # watchdog does not kill a working agent.
      issue_id = "issue-hook-active"
      identifier = "STALL-HOOK"

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

      # A claude hook fires for this agent -> liveness refreshed to now.
      refreshed = Orchestrator.note_agent_activity_state(state, identifier)

      next = Orchestrator.apply_stall_check_for_test(refreshed, 60_000)

      assert Map.has_key?(next.running, issue_id), "hook-active entry must NOT be stall-restarted"
      assert next.retry_attempts == %{}
    end

    test "note_agent_activity_state is a no-op for an unknown identifier" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert Orchestrator.note_agent_activity_state(state, "NOPE") == state
    end
  end

  describe "ticket.<blocker>.branch.push auto-resumes paused blockees" do
    setup do
      identifier = "BLOCKEE-#{System.unique_integer([:positive])}"
      :ok = SubscriptionStore.attach(identifier)
      on_exit(fn -> :ok = SubscriptionStore.stop(identifier) end)

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
        SubscriptionStore.add_subscription(
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
        SubscriptionStore.add_subscription(
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
        SubscriptionStore.add_subscription(
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

    test "auto-resume refreshes last_codex_timestamp so the next stall tick gives a full window",
         %{identifier: identifier, fake_pid: fake_pid} do
      # Reproduces the live --test3 run #3 race: a blockee paused for
      # >stall_timeout_ms then auto-resumed back to :working, only to
      # be killed by the very next stall watchdog scan because its
      # `last_codex_timestamp` still reflected the pre-pause activity.
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.branch.push",
          "blocker:auto"
        )

      issue_id = "issue-resume-timestamp"

      # Last codex activity is 14 minutes old — well past the default
      # 5-minute stall window.
      stale_at = DateTime.add(DateTime.utc_now(), -840, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :paused},
            paused_at: stale_at
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      before_ms = System.monotonic_time(:millisecond)
      next = Orchestrator.apply_branch_push_for_test(state, "99")
      after_ms = System.monotonic_time(:millisecond)

      entry = next.running[issue_id]
      assert entry.control.status == :working

      # The timestamp must be NOT stale_at any more. We test it's
      # within the wall-clock window of when apply ran (not strict
      # equality to avoid clock-skew flakes).
      assert %DateTime{} = entry.last_codex_timestamp
      ts_diff_ms = DateTime.diff(DateTime.utc_now(), entry.last_codex_timestamp, :millisecond)

      assert ts_diff_ms <= after_ms - before_ms + 1_000,
             "last_codex_timestamp must be refreshed to ~now() on auto-resume"
    end

    test "blocker's own entry is never resumed against its own push", %{
      identifier: blocker_identifier,
      fake_pid: fake_pid
    } do
      # An agent could theoretically be subscribed to its own push topic
      # (via aiur_subscribe). Defensive: don't resume the publisher itself.
      :ok =
        SubscriptionStore.add_subscription(
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

  describe "REPL session teardown tracking (U7)" do
    test "{:repl_session_runtime, ...} records the pane id + os pid on the running entry" do
      issue_id = "issue-repl-track"
      identifier = "RPL-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            repl_pane_id: nil,
            repl_os_pid: nil
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      {:noreply, next} =
        Orchestrator.handle_info(
          {:repl_session_runtime, issue_id, %{pane_id: "%77", os_pid: 4242}},
          state
        )

      entry = next.running[issue_id]
      assert entry.repl_pane_id == "%77"
      assert entry.repl_os_pid == 4242
    end

    test "{:repl_session_runtime, ...} for an unknown issue is a no-op" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:repl_session_runtime, "nope", %{pane_id: "%1", os_pid: 1}},
                 state
               )
    end

    test "deactivate tears down a tracked REPL session and still deactivates the entry" do
      test_root =
        Path.join(System.tmp_dir!(), "aiur-orch-repl-teardown-#{System.unique_integer([:positive])}")

      issue_id = "issue-repl-teardown"
      issue_identifier = "RPT-1"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

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
              control: %{status: :working},
              # os pid nil keeps graceful_kill a no-op; the pane kill targets a
              # bogus id the real tmux server rejects harmlessly — the point is
              # the deactivate path's kill_repl_session runs cleanly.
              repl_pane_id: "%repl-bogus",
              repl_os_pid: nil
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

        entry = Map.fetch!(updated_state.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        refute Process.alive?(agent_pid)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "whole-app shutdown reaping (terminate/2)" do
    @tag skip: @pgrep_skip_reason
    test "reaps every running entry's headless agent subtree on shutdown" do
      # Mirror the headless backend: a `bash -lc` wrapper that forks a child
      # it never execs. On whole-app shutdown the supervisor brutally kills
      # the AgentRunner task (skipping `after stop_session`), so without a
      # terminate/2 reap the child reparents to init and keeps committing.
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      child_pid = shutdown_wait_for_child(bash_pid, 2_000)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      assert is_integer(child_pid)
      assert shutdown_os_alive?(child_pid)

      issue_id = "issue-shutdown-reap"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: "SHD-1",
            issue: %Issue{id: issue_id, state: "in-progress", identifier: "SHD-1"},
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            headless_os_pid: bash_pid
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert :ok = Orchestrator.terminate(:shutdown, state)

      refute shutdown_os_alive?(bash_pid)
      refute shutdown_os_alive?(child_pid)
    end

    defp shutdown_wait_for_child(parent, budget_ms) do
      deadline = System.monotonic_time(:millisecond) + budget_ms
      do_shutdown_wait_for_child(parent, deadline)
    end

    defp do_shutdown_wait_for_child(parent, deadline) do
      first_child =
        case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
          {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1) |> List.first()
          _ -> nil
        end

      cond do
        is_integer(first_child) ->
          first_child

        System.monotonic_time(:millisecond) >= deadline ->
          nil

        true ->
          Process.sleep(25)
          do_shutdown_wait_for_child(parent, deadline)
      end
    end

    defp shutdown_os_alive?(pid),
      do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
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

  describe "system default-branch push stale-agent safety" do
    test "topic parser extracts the branch from a system branch push" do
      assert {:ok, "main"} =
               Orchestrator.parse_system_branch_push_topic_for_test("system.main.branch.push")

      assert :nomatch =
               Orchestrator.parse_system_branch_push_topic_for_test("ticket.99.branch.push")
    end

    test "default branch push stops working agents and releases claims" do
      issue_a = %Issue{id: "issue-main-a", identifier: "560", state: "in-progress"}
      issue_b = %Issue{id: "issue-main-b", identifier: "561", state: "in-progress"}
      issue_paused = %Issue{id: "issue-paused", identifier: "562", state: "in-progress"}

      pid_a = spawn(fn -> Process.sleep(:infinity) end)
      pid_b = spawn(fn -> Process.sleep(:infinity) end)
      pid_paused = spawn(fn -> Process.sleep(:infinity) end)
      ref_a = Process.monitor(pid_a)
      ref_b = Process.monitor(pid_b)
      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        running: %{
          issue_a.id => %{
            pid: pid_a,
            ref: nil,
            identifier: issue_a.identifier,
            issue: issue_a,
            control: %{status: :working},
            started_at: started_at
          },
          issue_b.id => %{
            pid: pid_b,
            ref: nil,
            identifier: issue_b.identifier,
            issue: issue_b,
            control: %{status: :working},
            started_at: started_at
          },
          issue_paused.id => %{
            pid: pid_paused,
            ref: nil,
            identifier: issue_paused.identifier,
            issue: issue_paused,
            control: %{status: :paused},
            started_at: started_at
          }
        },
        claimed: MapSet.new([issue_a.id, issue_b.id, issue_paused.id]),
        retry_attempts: %{issue_a.id => %{attempt: 1}, issue_b.id => %{attempt: 1}}
      }

      next =
        Orchestrator.apply_system_branch_push_for_test(state, "main", %{
          sha: "abc123"
        })

      refute Map.has_key?(next.running, issue_a.id)
      refute Map.has_key?(next.running, issue_b.id)
      assert Map.has_key?(next.running, issue_paused.id)
      refute MapSet.member?(next.claimed, issue_a.id)
      refute MapSet.member?(next.claimed, issue_b.id)
      assert MapSet.member?(next.claimed, issue_paused.id)
      refute Map.has_key?(next.retry_attempts, issue_a.id)
      refute Map.has_key?(next.retry_attempts, issue_b.id)

      assert_receive {:DOWN, ^ref_a, :process, ^pid_a, :killed}, 500
      assert_receive {:DOWN, ^ref_b, :process, ^pid_b, :killed}, 500
      assert Process.alive?(pid_paused)

      Process.exit(pid_paused, :kill)
    end

    test "non-default system branch push leaves active agents alone" do
      issue = %Issue{id: "issue-feature", identifier: "563", state: "in-progress"}
      pid = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        running: %{
          issue.id => %{
            pid: pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            control: %{status: :working},
            started_at: started_at
          }
        },
        claimed: MapSet.new([issue.id]),
        retry_attempts: %{}
      }

      next = Orchestrator.apply_system_branch_push_for_test(state, "release", %{sha: "def456"})

      assert Map.has_key?(next.running, issue.id)
      assert MapSet.member?(next.claimed, issue.id)
      assert Process.alive?(pid)

      Process.exit(pid, :kill)
    end

    test "configured non-main base branch stops agents while main does not" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "trunk")

      issue = %Issue{id: "issue-trunk", identifier: "564", state: "in-progress"}
      pid = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(pid)
      started_at = DateTime.utc_now()

      try do
        state = %Orchestrator.State{
          running: %{
            issue.id => %{
              pid: pid,
              ref: nil,
              identifier: issue.identifier,
              issue: issue,
              control: %{status: :working},
              started_at: started_at
            }
          },
          claimed: MapSet.new([issue.id]),
          retry_attempts: %{issue.id => %{attempt: 1}}
        }

        after_main = Orchestrator.apply_system_branch_push_for_test(state, "main", %{sha: "main123"})

        assert Map.has_key?(after_main.running, issue.id)
        assert MapSet.member?(after_main.claimed, issue.id)
        assert Process.alive?(pid)

        after_trunk =
          Orchestrator.apply_system_branch_push_for_test(after_main, "trunk", %{sha: "trunk123"})

        refute Map.has_key?(after_trunk.running, issue.id)
        refute MapSet.member?(after_trunk.claimed, issue.id)
        refute Map.has_key?(after_trunk.retry_attempts, issue.id)

        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500
      after
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end
  end
end
