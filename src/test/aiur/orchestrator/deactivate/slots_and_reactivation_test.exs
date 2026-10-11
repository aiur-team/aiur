defmodule Aiur.Orchestrator.Deactivate.SlotsAndReactivationTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.Slots

  describe "slot counting on the public status snapshot" do
    test "deactivated entries do not consume a slot in the (N/M) counter" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-slot-counting")

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
        status = Slots.slot_status(state)

        assert status.active == 1
        assert status.paused == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "all-:deactivated running map frees every slot" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-slot-all-deact")

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

        status = Slots.slot_status(state)

        assert status.active == 0
        assert status.paused == 0
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "label-flip back to active reactivates a :deactivated entry" do
    test "human-review → in-progress on a :deactivated entry routes through reactivate_issue" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-relabel-active")

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

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

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
end
