defmodule Aiur.Orchestrator.Deactivate.BlockerUnblockReadyTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{EventTopics, PushRouting}

  import Aiur.OrchestratorDeactivateSupport

  describe "ticket.<blocker>.agent.unblocked auto-resumes paused blockees" do
    setup do
      reset_branch_refs()

      # Isolate subscription persistence to a unique tmp dir. `attach` loads
      # any `<repo>.<identifier>.subscriptions.json` left on disk, and the
      # `unique_integer` identifier can repeat across separate `mix test`
      # runs (the counter resets per VM boot). Without isolation a sibling
      # test's persisted `ticket.99.agent.unblocked` subscription leaks back in
      # and wrongly auto-resumes a blockee that should stay paused.
      tmp_dir =
        Aiur.TestSupport.tmp_root!("aiur_blockee_subscr")

      File.mkdir_p!(tmp_dir)
      original_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))
      original_runtime_state_dir = Application.get_env(:aiur, :runtime_state_dir)
      Application.put_env(:aiur, :runtime_state_dir, Path.join(tmp_dir, "runtime-state"))

      identifier = "BLOCKEE-#{System.unique_integer([:positive])}"
      :ok = SubscriptionStore.attach(identifier)

      on_exit(fn ->
        reset_branch_refs()
        :ok = SubscriptionStore.stop(identifier)

        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end

        if original_runtime_state_dir do
          Application.put_env(:aiur, :runtime_state_dir, original_runtime_state_dir)
        else
          Application.delete_env(:aiur, :runtime_state_dir)
        end

        File.rm_rf(tmp_dir)
      end)

      fake_pid = spawn_link(fn -> fake_agent_loop() end)

      %{identifier: identifier, fake_pid: fake_pid}
    end

    test "branch push before consumer subscription corroborates later final unblock", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      empty = %Orchestrator.State{running: %{}}

      EventTopics.route(empty, %{
        topic: "ticket.99.branch.push",
        ref: blocker_ref(),
        sha: blocker_sha()
      })

      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-push-before-subscribe"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      next =
        EventTopics.route(state, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(next.running, [issue_id, :control, :status]) == :paused

      assert %{action: :resume, status: :accepted} =
               next.control_lifecycle.records[next.control_lifecycle.pending[issue_id]]

      next = confirm_pending_control(next, issue_id, :working)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "ready unblock survives restart ordering until the consumer is restored", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      empty = %Orchestrator.State{running: %{}}

      empty =
        EventTopics.route(empty, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      EventTopics.route(empty, %{
        topic: "ticket.99.branch.push",
        ref: blocker_ref(),
        sha: blocker_sha()
      })

      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-restored-after-ready"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      restored = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      resumed = PushRouting.reconcile_pending_auto_resumes(restored)
      assert get_in(resumed.running, [issue_id, :control, :status]) == :paused
      resumed = confirm_pending_control(resumed, issue_id, :working)
      assert get_in(resumed.running, [issue_id, :control, :status]) == :working
      assert_ready_unblock(nil)
    end

    test "parked blockee ignores branch push then consumes explicit unblocked and resumes", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-blockee-1"

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: control_issue(issue_id, identifier),
              started_at: DateTime.utc_now(),
              control: confirmed_control(:paused)
            }
            |> Map.merge(blocker_pause_fields())
            |> with_blocker_push()
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      after_push = EventTopics.route(state, %{topic: "ticket.99.branch.push", ref: blocker_ref(), sha: blocker_sha()})
      assert get_in(after_push.running, [issue_id, :control, :status]) == :paused

      next =
        EventTopics.route(after_push, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      next = confirm_pending_control(next, issue_id, :working)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "unblock before pause is retained then consumed exactly once", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-blockee-2"

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: control_issue(issue_id, identifier),
              started_at: DateTime.utc_now(),
              control: confirmed_control(:working)
            }
            |> Map.merge(blocker_pause_fields())
            |> with_blocker_push()
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.apply_agent_unblocked(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :working
      assert get_in(next.running, [issue_id, :pending_auto_resume, :blocker_identifier]) == "99"

      paused = put_in(next.running[issue_id].control.status, :paused)
      resumed = PushRouting.reconcile_pending_auto_resumes(paused)

      assert get_in(resumed.running, [issue_id, :control, :status]) == :paused
      assert get_in(resumed.running, [issue_id, :pending_auto_resume, :blocker_identifier]) == "99"
      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})
      resumed = confirm_pending_control(resumed, issue_id, :working)
      assert get_in(resumed.running, [issue_id, :control, :status]) == :working
      refute Map.has_key?(resumed.running[issue_id], :pending_auto_resume)

      assert PushRouting.reconcile_pending_auto_resumes(resumed) == resumed
      assert PushRouting.apply_agent_unblocked(resumed, "99") == resumed
    end

    test "unblock stays durable until every subscribed consumer reaches its matching pause", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      late_identifier = "LATE-BLOCKEE-#{System.unique_integer([:positive])}"
      :ok = SubscriptionStore.attach(late_identifier)

      on_exit(fn -> SubscriptionStore.stop(late_identifier) end)

      for blockee <- [identifier, late_identifier] do
        :ok =
          SubscriptionStore.add_subscription(
            blockee,
            "ticket.99.agent.unblocked",
            "blocker:auto"
          )
      end

      first_issue_id = "issue-first-blockee"
      late_issue_id = "issue-late-blockee"

      first_entry = %{
        pid: fake_pid,
        ref: nil,
        identifier: identifier,
        issue: control_issue(first_issue_id, identifier),
        started_at: DateTime.utc_now(),
        control: confirmed_control(:paused)
      }

      late_pid = spawn_link(fn -> fake_agent_loop() end)

      late_entry = %{
        pid: late_pid,
        ref: nil,
        identifier: late_identifier,
        issue: control_issue(late_issue_id, late_identifier),
        started_at: DateTime.utc_now(),
        control: confirmed_control(:working)
      }

      state = %Orchestrator.State{
        running: %{
          first_issue_id => Map.merge(first_entry, blocker_pause_fields()),
          late_issue_id => late_entry
        },
        claimed: MapSet.new([first_issue_id, late_issue_id]),
        max_concurrent_agents: 6
      }

      record_blocker_ref()

      after_unblock =
        EventTopics.route(state, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :paused
      assert get_in(after_unblock.running, [late_issue_id, :control, :status]) == :working

      after_unblock = confirm_pending_control(after_unblock, first_issue_id, :working)
      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :working

      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})

      after_late_pause =
        EventTopics.route(after_unblock, %{
          topic: "ticket.#{late_identifier}.agent.pause.request",
          payload: %{reason: "dependency", blocker_identifier: "99"}
        })

      assert get_in(after_late_pause.running, [late_issue_id, :control, :status]) == :working
      after_late_pause = confirm_pending_control(after_late_pause, late_issue_id, :paused)
      assert get_in(after_late_pause.running, [late_issue_id, :control, :status]) == :paused

      reconciled = PushRouting.reconcile_pending_auto_resumes(after_late_pause)

      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :paused
      reconciled = confirm_pending_control(reconciled, late_issue_id, :working)
      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :working
      assert_ready_unblock(nil)
    end

    test "unblock stays durable for a declared consumer that has not started yet", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      late_identifier = "DECLARED-BLOCKEE-#{System.unique_integer([:positive])}"
      late_issue_id = "issue-declared-blockee"
      :ok = SubscriptionStore.attach(late_identifier)

      on_exit(fn -> SubscriptionStore.stop(late_identifier) end)

      for blockee <- [identifier, late_identifier] do
        :ok =
          SubscriptionStore.add_subscription(
            blockee,
            "ticket.99.agent.unblocked",
            "blocker:auto"
          )
      end

      first_issue_id = "issue-running-blockee"

      first_entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(first_issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      declared_issue = %Issue{
        id: late_issue_id,
        identifier: late_identifier,
        state: "in-progress",
        tracker_identity: tracker_identity(late_issue_id),
        blocked_by: [%{id: "blocker-issue", identifier: "99", state: "in-progress"}]
      }

      state = %Orchestrator.State{
        running: %{first_issue_id => first_entry},
        last_polled_issues: %{late_issue_id => declared_issue},
        claimed: MapSet.new([first_issue_id]),
        max_concurrent_agents: 6
      }

      record_blocker_ref()

      after_unblock =
        EventTopics.route(state, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :paused
      after_unblock = confirm_pending_control(after_unblock, first_issue_id, :working)
      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :working
      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})

      late_pid = spawn_link(fn -> fake_agent_loop() end)

      late_entry =
        %{
          pid: late_pid,
          ref: nil,
          identifier: late_identifier,
          issue: declared_issue,
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      started = %{
        after_unblock
        | running: Map.put(after_unblock.running, late_issue_id, late_entry),
          claimed: MapSet.put(after_unblock.claimed, late_issue_id)
      }

      reconciled = PushRouting.reconcile_pending_auto_resumes(started)

      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :paused
      reconciled = confirm_pending_control(reconciled, late_issue_id, :working)
      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :working
      assert_ready_unblock(nil)
    end
  end
end
