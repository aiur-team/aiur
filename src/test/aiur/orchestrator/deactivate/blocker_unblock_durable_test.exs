defmodule Aiur.Orchestrator.Deactivate.BlockerUnblockDurableTest do
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

    test "final unblock requires canonical ref and SHA corroborated by branch push", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-corroborated-unblock"

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

      invalid_payloads = [
        %{},
        %{ref: blocker_ref()},
        %{sha: blocker_sha()},
        %{ref: 123, sha: blocker_sha()},
        %{ref: blocker_ref(), sha: 123},
        %{ref: "aiur/99-dependency", sha: blocker_sha()},
        %{ref: blocker_ref(), sha: "short"}
      ]

      for payload <- invalid_payloads do
        next = EventTopics.route(state, %{topic: "ticket.99.agent.unblocked", payload: payload})
        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end

      unblock = %{topic: "ticket.99.agent.unblocked", payload: %{ref: blocker_ref(), sha: blocker_sha()}}
      awaiting_push = EventTopics.route(state, unblock)
      assert get_in(awaiting_push.running, [issue_id, :control, :status]) == :paused

      mismatches = [
        %{ref: "refs/heads/aiur/99-other", sha: blocker_sha()},
        %{ref: blocker_ref(), sha: String.duplicate("b", 40)}
      ]

      for payload <- mismatches do
        next = EventTopics.route(awaiting_push, %{topic: "ticket.99.agent.unblocked", payload: payload})
        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end

      pushed = EventTopics.route(awaiting_push, %{topic: "ticket.99.branch.push", ref: blocker_ref(), sha: blocker_sha()})
      assert get_in(pushed.running, [issue_id, :control, :status]) == :paused
      pushed = confirm_pending_control(pushed, issue_id, :working)
      assert get_in(pushed.running, [issue_id, :control, :status]) == :working
      assert EventTopics.route(pushed, %{topic: "ticket.99.branch.push", ref: blocker_ref(), sha: blocker_sha()}) == pushed
    end

    test "retained readiness only drains its matching blocker-pause generation", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-pause-generation"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
        |> Map.merge(blocker_pause_fields())
        |> with_blocker_push()

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      ready = PushRouting.apply_agent_unblocked(state, "99")
      assert get_in(ready.running, [issue_id, :pending_auto_resume, :pause_generation]) == 1

      for reason <- [:operator_pause, :label_override, :max_agent_duration, :ci_wait] do
        unrelated =
          ready
          |> put_in([Access.key(:running), issue_id, :control, :status], :paused)
          |> put_in([Access.key(:running), issue_id, :paused_reason], reason)

        reconciled = PushRouting.reconcile_pending_auto_resumes(unrelated)
        assert get_in(reconciled.running, [issue_id, :control, :status]) == :paused
        refute Map.has_key?(reconciled.running[issue_id], :pending_auto_resume)
      end

      next_generation =
        ready
        |> put_in([Access.key(:running), issue_id, :control, :status], :paused)
        |> put_in([Access.key(:running), issue_id, :blocker_pause, :generation], 2)

      reconciled = PushRouting.reconcile_pending_auto_resumes(next_generation)
      assert get_in(reconciled.running, [issue_id, :control, :status]) == :paused
      refute Map.has_key?(reconciled.running[issue_id], :pending_auto_resume)

      advanced_counter =
        ready
        |> put_in([Access.key(:running), issue_id, :control, :status], :paused)
        |> put_in([Access.key(:running), issue_id, :blocker_pause_generation], 2)

      reconciled = PushRouting.reconcile_pending_auto_resumes(advanced_counter)
      assert get_in(reconciled.running, [issue_id, :control, :status]) == :paused
      refute Map.has_key?(reconciled.running[issue_id], :pending_auto_resume)
    end

    test "provisional unblocked payloads never resume or stamp readiness", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")

      issue_id = "issue-provisional-unblock"

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :paused}
            }
            |> Map.merge(blocker_pause_fields())
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      record_blocker_ref()

      events = [
        %{topic: "ticket.99.agent.unblocked", temporary_stub: true, ref: blocker_ref(), sha: blocker_sha()},
        %{"temporary_stub" => true, "ref" => blocker_ref(), "sha" => blocker_sha(), topic: "ticket.99.agent.unblocked"},
        %{topic: "ticket.99.agent.unblocked", payload: %{temporary_stub: true, ref: blocker_ref(), sha: blocker_sha()}},
        %{"payload" => %{"temporary_stub" => true, "ref" => blocker_ref(), "sha" => blocker_sha()}, topic: "ticket.99.agent.unblocked"}
      ]

      for event <- events do
        next = EventTopics.route(state, event)
        assert get_in(next.running, [issue_id, :control, :status]) == :paused
        refute Map.has_key?(next.running[issue_id], :pending_auto_resume)
      end
    end

    test "paused blockee NOT subscribed to this blocker stays paused", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      # Subscribe to a DIFFERENT blocker's unblock; the 99 unblock should be
      # treated as not relevant to this entry.
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.42.agent.unblocked",
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

      next = PushRouting.apply_agent_unblocked(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "auto-resume waits to refresh last_codex_timestamp until the worker confirms",
         %{identifier: identifier, fake_pid: fake_pid} do
      # Reproduces the live --test3 run #3 race: a blockee paused for
      # >stall_timeout_ms then requested a resume back to :working, only to
      # be killed by the very next stall watchdog scan because its
      # `last_codex_timestamp` still reflected the pre-pause activity.
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-resume-timestamp"

      # Last codex activity is 14 minutes old — well past the default
      # 5-minute stall window.
      stale_at = DateTime.add(DateTime.utc_now(), -840, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: %Issue{
                id: issue_id,
                state: "in-progress",
                identifier: identifier,
                tracker_identity: tracker_identity(issue_id)
              },
              started_at: stale_at,
              last_codex_timestamp: stale_at,
              control: confirmed_control(:paused),
              paused_at: stale_at
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

      entry = next.running[issue_id]
      assert entry.control.status == :paused
      assert entry.last_codex_timestamp == stale_at

      assert %{action: :resume, status: :accepted} =
               next.control_lifecycle.records[next.control_lifecycle.pending[issue_id]]
    end

    test "blocker's own entry is never resumed against its own unblocked event", %{
      identifier: blocker_identifier,
      fake_pid: fake_pid
    } do
      # An agent could theoretically be subscribed to its own unblock topic
      # (via aiur_subscribe). Defensive: don't resume the publisher itself.
      :ok =
        SubscriptionStore.add_subscription(
          blocker_identifier,
          "ticket.#{blocker_identifier}.agent.unblocked",
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

      next = PushRouting.apply_agent_unblocked(state, blocker_identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end
  end
end
