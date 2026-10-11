defmodule Aiur.Orchestrator.Deactivate.BlockerUnblockPauseTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CiLifecycle, GithubBudgetPause}
  alias Aiur.Orchestrator.{EventTopics, PauseResume, PushRouting}

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

    test "dependency pause requests establish a blocker-specific generation", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      issue_id = "issue-dependency-pause"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: control_issue(issue_id, identifier),
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      paused =
        PushRouting.maybe_pause_on_request(state, identifier, %{
          payload: %{reason: "dependency", blocker_identifier: "99"}
        })

      assert get_in(paused.running, [issue_id, :control, :status]) == :working
      assert get_in(paused.running, [issue_id, :pending_pause_reason, :reason]) == :blocker_dependency
      assert get_in(paused.running, [issue_id, :blocker_pause]) == %{blocker_identifier: "99", generation: 1}

      paused = confirm_pending_control(paused, issue_id, :paused)
      assert get_in(paused.running, [issue_id, :control, :status]) == :paused
      assert get_in(paused.running, [issue_id, :paused_reason]) == :blocker_dependency

      generic = PushRouting.maybe_pause_on_request(state, identifier, %{})
      assert get_in(generic.running, [issue_id, :control, :status]) == :working
      assert get_in(generic.running, [issue_id, :pending_pause_reason, :reason]) == :agent_pause_request
      refute Map.has_key?(generic.running[issue_id], :blocker_pause)

      generic = confirm_pending_control(generic, issue_id, :paused)
      assert get_in(generic.running, [issue_id, :paused_reason]) == :agent_pause_request
    end

    test "budget readiness before pause confirmation drains through the real control lifecycle", %{
      identifier: identifier
    } do
      issue_id = "issue-budget-ready-before-pause"
      agent_pid = control_test_agent(self())
      reset_at_ms = System.system_time(:millisecond) - 1

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: identifier,
            issue: control_issue(issue_id, identifier),
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      pause_pending =
        PushRouting.maybe_pause_on_request(state, identifier, %{
          payload: %{reason: "github_budget_hold", resource: "graphql", reset_at_ms: reset_at_ms}
        })

      receive_barrier({:ci_wait_control, {:pause_agent, _pause_request_id, 101}})
      # The fleet recovery signal schedules a jittered per-entry wake rather
      # than resuming synchronously; drive the expiry path the way the
      # orchestrator's timer handler does.
      recover_signaled = PushRouting.recover_github_budget_pauses(pause_pending, reset_at_ms)
      ready = PushRouting.recover_github_budget_pause(recover_signaled, identifier, 1, reset_at_ms)
      assert get_in(ready.running, [issue_id, :pending_auto_resume, :pause_generation]) == 1

      paused = confirm_pending_control(ready, issue_id, :paused)
      assert paused.running[issue_id].paused_reason == :github_budget_hold

      resume_pending = PushRouting.reconcile_pending_auto_resumes(paused)
      receive_barrier({:ci_wait_control, {:resume_agent, resume_request_id, 101}})

      repeated = PushRouting.reconcile_pending_auto_resumes(resume_pending)
      assert repeated.control_lifecycle.pending[issue_id] == resume_request_id
      refute_received {:ci_wait_control, {:resume_agent, _request_id, 101}}

      working = confirm_pending_control(repeated, issue_id, :working)
      assert working.running[issue_id].control.status == :working
      refute Map.has_key?(working.running[issue_id], :pending_auto_resume)
      refute Map.has_key?(working.running[issue_id], :github_budget_pause)
    end

    test "capacity-deferred budget readiness drains after a slot opens", %{
      identifier: identifier
    } do
      issue_id = "issue-budget-capacity-deferred"
      busy_issue_id = "issue-occupying-slot"
      agent_pid = control_test_agent(self())
      reset_at_ms = System.system_time(:millisecond) - 1

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: identifier,
            issue: control_issue(issue_id, identifier),
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 1
      }

      pause_pending =
        PushRouting.maybe_pause_on_request(state, identifier, %{
          payload: %{reason: "github_budget_hold", resource: "core", reset_at_ms: reset_at_ms}
        })

      receive_barrier({:ci_wait_control, {:pause_agent, _pause_request_id, 101}})
      paused = confirm_pending_control(pause_pending, issue_id, :paused)

      busy_entry = %{
        identifier: "BUSY-1",
        issue: control_issue(busy_issue_id, "BUSY-1"),
        control: confirmed_control(:working)
      }

      full = put_in(paused.running[busy_issue_id], busy_entry)
      recover_signaled = PushRouting.recover_github_budget_pauses(full, reset_at_ms)
      deferred = PushRouting.recover_github_budget_pause(recover_signaled, identifier, 1, reset_at_ms)

      assert get_in(deferred.running, [issue_id, :pending_auto_resume, :pause_generation]) == 1
      refute_received {:ci_wait_control, {:resume_agent, _request_id, 101}}

      available = update_in(deferred.running, &Map.delete(&1, busy_issue_id))
      resume_pending = PushRouting.reconcile_pending_auto_resumes(available)
      receive_barrier({:ci_wait_control, {:resume_agent, _resume_request_id, 101}})

      working = confirm_pending_control(resume_pending, issue_id, :working)
      assert working.running[issue_id].control.status == :working
      refute Map.has_key?(working.running[issue_id], :pending_auto_resume)
    end

    test "stale budget recovery cannot release operator or dependency replacements", %{
      identifier: identifier
    } do
      issue_id = "issue-budget-replaced"
      reset_at_ms = System.system_time(:millisecond) - 1

      base = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: control_test_agent(self()),
            ref: nil,
            identifier: identifier,
            issue: control_issue(issue_id, identifier),
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      budget_pending =
        PushRouting.maybe_pause_on_request(base, identifier, %{
          payload: %{reason: "github_budget_hold", resource: "graphql", reset_at_ms: reset_at_ms}
        })

      receive_barrier({:ci_wait_control, {:pause_agent, _pause_request_id, 101}})
      budget_paused = confirm_pending_control(budget_pending, issue_id, :paused)
      generation = budget_paused.running[issue_id].github_budget_pause.generation

      replacements = [
        {:operator_pause, fn state -> elem(PauseResume.pause_agent_reply(state, identifier), 1) end},
        {:blocker_dependency,
         fn state ->
           entry =
             state.running[issue_id]
             |> Map.put(:blocker_pause_generation, 1)
             |> Map.put(:blocker_pause, %{blocker_identifier: "99", generation: 1})
             |> GithubBudgetPause.clear_context()

           elem(PauseResume.request_pause(state, entry, entry.issue, :blocker_dependency), 1)
         end}
      ]

      for {reason, replace} <- replacements do
        replaced = replace.(budget_paused)
        assert replaced.running[issue_id].paused_reason == reason
        refute Map.has_key?(replaced.running[issue_id], :github_budget_pause)

        unchanged = PushRouting.recover_github_budget_pause(replaced, identifier, generation, reset_at_ms)
        assert unchanged.running[issue_id].control.status == :paused
        refute_received {:ci_wait_control, {:resume_agent, _request_id, 101}}
      end
    end

    test "real control transitions replace blocker context before final unblock", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      record_blocker_ref()

      issue_id = "issue-replaced-pause"
      issue = control_issue(issue_id, identifier, "ci-wait")

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused),
          pending_auto_resume: %{pause_generation: 1}
        }
        |> Map.merge(blocker_pause_fields())

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      tracker_paused = PauseResume.pause_issue_for_label_override(state, issue)
      assert tracker_paused.running[issue_id].paused_reason == :blocker_dependency
      assert Map.has_key?(tracker_paused.running[issue_id], :blocker_pause)
      assert Map.has_key?(tracker_paused.running[issue_id], :pending_auto_resume)

      transitions = [
        {:ci_wait, fn current -> CiLifecycle.pause_issue_for_ci_wait(current, issue) end},
        {:operator_pause, fn current -> elem(PauseResume.pause_agent_reply(current, identifier), 1) end},
        {:max_agent_duration,
         fn current ->
           paused_entry = Map.put(current.running[issue_id], :paused_reason, :max_agent_duration)
           PauseResume.transition_control_status(current, paused_entry, :paused, "max_agent_duration")
         end}
      ]

      for {reason, transition} <- transitions do
        transitioned = transition.(state)
        assert transitioned.running[issue_id].paused_reason == reason
        refute Map.has_key?(transitioned.running[issue_id], :blocker_pause)
        refute Map.has_key?(transitioned.running[issue_id], :pending_auto_resume)

        next =
          EventTopics.route(transitioned, %{
            topic: "ticket.99.agent.unblocked",
            payload: %{ref: blocker_ref(), sha: blocker_sha()}
          })

        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end
    end

    test "direct final unblock requires the current blocker-pause reason and generation", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      record_blocker_ref()
      issue_id = "issue-current-generation"

      matching_entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      mismatched_entries = [
        Map.put(matching_entry, :paused_reason, :operator_pause),
        put_in(matching_entry, [:blocker_pause, :generation], 2)
      ]

      for entry <- mismatched_entries do
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
      end
    end
  end
end
