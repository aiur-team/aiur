defmodule Aiur.Orchestrator.ReconcilerTest do
  use Aiur.TestSupport

  alias Aiur.{Alerts, Config, Issue}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{PauseResume, Reconciler, State}
  alias Aiur.TrackerIdentity
  alias Aiur.Workspace.Layout

  describe "reconcile_running_issue_states/4" do
    test "returns state unchanged for empty list" do
      state = %State{running: %{"issue-1" => %{pid: self()}}}
      active = MapSet.new(["todo"])
      terminal = MapSet.new(["done"])

      assert Reconciler.reconcile_running_issue_states([], state, active, terminal) == state
    end

    test "emits an attention alert when the local label override disagrees with the tracker" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-divergence.agent.attention.state_divergence")
      :ok = Exchange.subscribe("ticket.I-divergence.agent.attention.state_divergence.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-divergence", identifier: "I-divergence", state: "in-progress", paused: false}

      state = %State{
        running: %{
          "issue-divergence" => %{
            identifier: "I-divergence",
            issue: issue,
            control: %{status: :paused},
            paused_reason: :label_override
          }
        }
      }

      state = Reconciler.report_label_divergence(state, issue)

      assert_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence"} = event}, 500
      assert event["reason"] =~ "local=paused(label_override) tracker=agent:in-progress"

      assert Reconciler.report_label_divergence(state, issue) == state
      refute_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence"}}, 100

      recovered_issue = %{issue | paused: true}
      recovered = Reconciler.report_label_divergence(state, recovered_issue)

      assert_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence.resolved"} = event},
                     500

      assert event["reason"] =~ "Resolved: State reconciliation detected divergence"
      refute Map.has_key?(recovered.running[issue.id], :label_divergence_reported)

      rearmed = Reconciler.report_label_divergence(recovered, issue)

      assert_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence"}}, 500
      assert get_in(rearmed.running, [issue.id, :label_divergence_reported]) =~ "local=paused"
    end

    test "reports a tracker pause while the local worker remains active" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-paused.agent.attention.state_divergence")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-paused", identifier: "I-paused", state: "in-progress", paused: true}

      state = %State{
        running: %{
          issue.id => %{identifier: issue.identifier, issue: issue, control: %{status: :working}}
        }
      }

      _state = Reconciler.report_label_divergence(state, issue)

      assert_receive {:event, %{topic: "ticket.I-paused.agent.attention.state_divergence"} = event}, 500
      assert event["reason"] =~ "local=working tracker=agent:paused"
    end

    test "reports a duration pause while the tracker remains active" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-duration.agent.attention.state_divergence")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-duration", identifier: "I-duration", state: "rework", paused: false}

      state = %State{
        running: %{
          issue.id => %{
            identifier: issue.identifier,
            issue: issue,
            control: %{status: :paused},
            paused_reason: :max_agent_duration
          }
        }
      }

      _state = Reconciler.report_label_divergence(state, issue)

      assert_receive {:event, %{topic: "ticket.I-duration.agent.attention.state_divergence"} = event}, 500
      assert event["reason"] =~ "local=paused(max_agent_duration) tracker=agent:rework"
      assert event["reason"] =~ "operator resume is required"
    end

    test "resolves and rearms a persisted divergence after restart" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-restart-divergence.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      assert :ok =
               Alerts.emit_custom(topic, "Persisted divergence",
                 issue: "I-restart-divergence",
                 reason: "Persisted divergence",
                 needs_attention: true,
                 severity: "warning"
               )

      assert_receive {:event, %{topic: ^topic}}, 500

      issue = %Issue{id: "issue-restart-divergence", identifier: "I-restart-divergence", state: "rework"}

      recovered = %State{active_attention_topics: MapSet.new([topic])}

      rearmed = Reconciler.report_label_divergence(recovered, issue)

      assert_receive {:event, %{topic: ^resolved_topic}}, 500
      refute Map.has_key?(rearmed.running, issue.id)

      paused = %{issue | paused: true}
      running = %{identifier: issue.identifier, issue: paused, control: %{status: :working}}

      rearmed = %{
        rearmed
        | running: %{issue.id => running},
          active_attention_topics: MapSet.new()
      }

      _ = Reconciler.report_label_divergence(rearmed, paused)

      assert_receive {:event, %{topic: ^topic}}, 500
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

    test "tracker pause does not take ownership from an existing local pause" do
      Enum.each([:operator_pause, :global_pause, :max_agent_duration, :agent_pause_request, :blocker_dependency], fn pause_reason ->
        suffix = Atom.to_string(pause_reason)

        issue = %Issue{
          id: "issue-owned-pause-#{suffix}",
          identifier: "I-owned-pause-#{suffix}",
          state: "rework",
          paused: true,
          tracker_identity: tracker_identity("I-owned-pause-#{suffix}")
        }

        entry = %{
          pid: self(),
          identifier: issue.identifier,
          issue: %{issue | paused: false},
          control: paused_control(),
          paused_reason: pause_reason,
          completed_provenance: pause_reason == :operator_pause
        }

        paused =
          Reconciler.reconcile_issue_state(
            issue,
            %State{running: %{issue.id => entry}},
            MapSet.new(["rework"]),
            MapSet.new(["done"]),
            fn _identity, _lifecycle -> :ok end
          )

        assert paused.running[issue.id].paused_reason == pause_reason
        assert paused.running[issue.id].control.status == :paused

        unpaused =
          Reconciler.reconcile_issue_state(
            %{issue | paused: false},
            paused,
            MapSet.new(["rework"]),
            MapSet.new(["done"]),
            fn _identity, _lifecycle -> :ok end
          )

        assert unpaused.running[issue.id].paused_reason == pause_reason
        assert unpaused.running[issue.id].control.status == :paused
        refute_receive {:resume_agent, _, _}, 10
      end)
    end

    test "tracker pause preserves pending local ownership through worker acknowledgement" do
      Enum.each([:operator_pause, :global_pause, :agent_pause_request], fn pause_reason ->
        suffix = Atom.to_string(pause_reason)

        issue = %Issue{
          id: "issue-pending-pause-#{suffix}",
          identifier: "I-pending-pause-#{suffix}",
          state: "rework",
          paused: true,
          tracker_identity: tracker_identity("I-pending-pause-#{suffix}")
        }

        entry = %{
          pid: self(),
          identifier: issue.identifier,
          issue: %{issue | paused: false},
          control: %{paused_control() | status: :working},
          started_at: DateTime.utc_now()
        }

        {{:ok, request_id}, requested} =
          PauseResume.pause_agent_reply(%State{running: %{issue.id => entry}}, issue.identifier)

        assert_receive {:pause_agent, ^request_id, 1}

        requested =
          update_in(requested.running[issue.id], fn pending_entry ->
            pending_entry
            |> put_in([:pending_pause_reason, :reason], pause_reason)
            |> Map.put(:completed_provenance, pause_reason == :agent_pause_request)
          end)

        tracker_paused =
          Reconciler.reconcile_issue_state(
            issue,
            requested,
            MapSet.new(["rework"]),
            MapSet.new(["done"]),
            fn _identity, _lifecycle -> :ok end
          )

        assert tracker_paused.running[issue.id].pending_pause_reason.reason == pause_reason
        assert tracker_paused.running[issue.id].pending_pause_reason.request_id == request_id

        assert {:noreply, acknowledged} =
                 Orchestrator.handle_info(
                   {:worker_control_state, issue.id, :paused, %{request_id: request_id, generation: 1}},
                   tracker_paused
                 )

        assert acknowledged.running[issue.id].paused_reason == pause_reason
        assert acknowledged.running[issue.id].control.status == :paused
      end)
    end

    test "resolves a persisted divergence for a terminal ticket without a running entry" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-terminal-restart.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      assert :ok =
               Alerts.emit_custom(topic, "Persisted divergence",
                 issue: "I-terminal-restart",
                 reason: "Persisted divergence",
                 needs_attention: true,
                 severity: "warning"
               )

      issue = %Issue{
        id: "issue-terminal-restart",
        identifier: "I-terminal-restart",
        state: "done",
        tracker_identity: tracker_identity("I-terminal-restart")
      }

      result =
        Reconciler.reconcile_issue_state(
          issue,
          %State{active_attention_topics: MapSet.new([topic])},
          MapSet.new(["rework"]),
          MapSet.new(["done"]),
          fn _identity, _lifecycle -> :ok end
        )

      assert_receive {:event, %{topic: ^resolved_topic}}, 500
      refute Map.has_key?(result.running, issue.id)
    end

    test "resolves a divergence before removing a terminal ticket" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-terminal-divergence.agent.attention.state_divergence")
      :ok = Exchange.subscribe("ticket.I-terminal-divergence.agent.attention.state_divergence.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{
        id: "issue-terminal-divergence",
        identifier: "I-terminal-divergence",
        state: "rework",
        tracker_identity: tracker_identity("I-terminal-divergence")
      }

      state = %State{
        running: %{
          issue.id => %{
            identifier: issue.identifier,
            issue: issue,
            control: paused_control(),
            paused_reason: :max_agent_duration
          }
        }
      }

      opened = Reconciler.report_label_divergence(state, issue)
      assert_receive {:event, %{topic: "ticket.I-terminal-divergence.agent.attention.state_divergence"}}, 500

      terminal = %{issue | state: "done"}

      result =
        Reconciler.reconcile_issue_state(
          terminal,
          opened,
          MapSet.new(["rework"]),
          MapSet.new(["done"]),
          fn _identity, _lifecycle -> :ok end
        )

      assert_receive {:event, %{topic: "ticket.I-terminal-divergence.agent.attention.state_divergence.resolved"}},
                     500

      assert %State{} = result
    end

    test "keeps a fenced terminal issue running during the grace window" do
      issue = terminal_fenced_issue()
      state = terminal_fenced_state(issue, DateTime.utc_now())

      result =
        Reconciler.reconcile_issue_state(
          issue,
          state,
          MapSet.new(["in-progress"]),
          MapSet.new(["closed"]),
          fn _observed_identity, _lifecycle -> :ok end
        )

      assert result == state
      assert Map.has_key?(result.running, issue.id)
    end

    test "records a fenced terminal issue before removing it after the grace window" do
      parent = self()
      identity = tracker_identity("I-fenced-terminal")
      issue = terminal_fenced_issue(identity)
      state = terminal_fenced_state(issue, DateTime.add(DateTime.utc_now(), -31, :second))

      result =
        Reconciler.reconcile_issue_state(
          issue,
          state,
          MapSet.new(["in-progress"]),
          MapSet.new(["closed"]),
          fn observed_identity, lifecycle ->
            send(parent, {observed_identity, lifecycle})
            :ok
          end
        )

      assert_received {^identity, :completed}
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
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

    test "stops an active worker when refreshed dispatch authorization is denied" do
      parent = self()
      identity = tracker_identity("I-authorization-denied")

      issue = %Issue{
        id: "issue-authorization-denied",
        identifier: "I-authorization-denied",
        state: "in-progress",
        tracker_identity: identity,
        dispatch_authorized?: false
      }

      entry = %{
        pid: nil,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now()
      }

      state = %State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}

      result =
        Reconciler.reconcile_issue_state(
          issue,
          state,
          MapSet.new(["in-progress"]),
          MapSet.new(),
          fn observed_identity, lifecycle ->
            send(parent, {observed_identity, lifecycle})
            :ok
          end
        )

      assert_received {^identity, :replaced}
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
    end
  end

  defp paused_control do
    %{
      status: :paused,
      can_interrupt: true,
      application_confirmation: :confirmed,
      generation: 1,
      version: 0
    }
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

  defp terminal_fenced_issue(identity \\ tracker_identity("I-fenced-terminal")) do
    %Issue{
      id: "issue-fenced-terminal",
      identifier: "I-fenced-terminal",
      state: "closed",
      tracker_identity: identity
    }
  end

  defp terminal_fenced_state(issue, opened_at) do
    %State{
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 1,
            opened_at: opened_at,
            pending_item_ids: MapSet.new([99])
          }
        }
      },
      claimed: MapSet.new([issue.id])
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
    test "releases a zero-turn before_run_failure so the active ticket can dispatch again" do
      issue = %Issue{
        id: "issue-zero-turn-brf",
        identifier: "issue-zero-turn-brf",
        state: "rework",
        tracker_identity: tracker_identity("I-zero-turn-before-run-failure")
      }

      task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> Process.sleep(:infinity) end)
      monitor_ref = Process.monitor(task.pid)

      on_exit(fn ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)

      entry = %{
        pid: task.pid,
        ref: task.ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        turn_count: 0,
        control: paused_control(),
        paused_reason: :before_run_failure
      }

      state = %State{
        running: %{issue.id => entry},
        claimed: MapSet.new([issue.id]),
        retry_attempts: %{issue.id => %{attempt: 1}},
        max_concurrent_agents: 10
      }

      result = Reconciler.maybe_reactivate_or_refresh(state, issue)

      assert_receive {:DOWN, ^monitor_ref, :process, _pid, _reason}
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
      refute Map.has_key?(result.retry_attempts, issue.id)
    end

    test "resumes a before_run_failure pause on an active-state issue" do
      issue = %Issue{
        id: "issue-brf",
        identifier: "issue-brf",
        state: "rework",
        tracker_identity: tracker_identity("I-before-run-failure")
      }

      entry = %{
        pid: self(),
        identifier: "issue-brf",
        issue: issue,
        turn_count: 1,
        control: paused_control(),
        paused_reason: :before_run_failure
      }

      state = %State{running: %{"issue-brf" => entry}, max_concurrent_agents: 10}

      result = Reconciler.maybe_reactivate_or_refresh(state, issue)

      # The parked agent is blocked in AgentRunner.wait_for_before_run_resume/3;
      # a transient hook failure must self-heal by delivering the resume signal
      # to its live pid, not sit paused forever.
      assert_receive {:resume_agent, request_id, 1}

      assert {:noreply, resumed_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, "issue-brf", :working, %{request_id: request_id, generation: 1}},
                 result
               )

      assert get_in(resumed_state.running, ["issue-brf", :control, :status]) == :working
    end

    test "auto-recovery of a persistently-failing before_run hook is bounded" do
      issue = %Issue{
        id: "issue-brf-loop",
        identifier: "issue-brf-loop",
        state: "rework",
        tracker_identity: tracker_identity("I-before-run-failure-loop")
      }

      entry = %{
        pid: self(),
        identifier: "issue-brf-loop",
        issue: issue,
        turn_count: 1,
        control: paused_control(),
        paused_reason: :before_run_failure
      }

      state = %State{running: %{"issue-brf-loop" => entry}, max_concurrent_agents: 10}

      polls = 20

      {final_state, resume_signals} =
        Enum.reduce(1..polls, {state, 0}, fn _poll, {acc, resume_signals} ->
          acc = Reconciler.maybe_reactivate_or_refresh(acc, issue)

          receive do
            {:resume_agent, request_id, 1} ->
              assert {:noreply, resumed_state} =
                       Orchestrator.handle_info(
                         {:worker_control_state, "issue-brf-loop", :working, %{request_id: request_id, generation: 1}},
                         acc
                       )

              current = resumed_state.running["issue-brf-loop"]

              # Simulate the agent re-running the hook, failing again, and
              # re-parking itself after it acknowledges the resume.
              reparked =
                current
                |> put_in([:control, :status], :paused)
                |> Map.put(:paused_reason, :before_run_failure)

              {%{resumed_state | running: Map.put(resumed_state.running, "issue-brf-loop", reparked)}, resume_signals + 1}
          after
            0 ->
              {acc, resume_signals}
          end
        end)

      assert resume_signals > 0,
             "a transient failure must get at least one automatic recovery attempt"

      # A persistent merge conflict must not resume on every poll forever; the
      # reconciler gives up well before the polling loop would.
      assert resume_signals < polls,
             "before_run_failure recovery must be bounded, not retry every poll forever"

      assert get_in(final_state.running["issue-brf-loop"], [:control, :status]) == :paused
    end
  end

  describe "reconcile_missing_running_issue_ids/3" do
    test "resolves a persisted divergence when no running entry reconstructs" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-orphaned-divergence.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      workspace = Layout.issue_workspace_path(Config.workspace_root(), "I-orphaned-divergence")
      File.mkdir_p!(workspace)
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      assert :ok =
               Alerts.emit_custom(topic, "Persisted divergence",
                 issue: "I-orphaned-divergence",
                 workspace: workspace,
                 reason: "Persisted divergence",
                 needs_attention: true,
                 severity: "warning",
                 central: true
               )

      state = %State{active_attention_topics: MapSet.new([topic])}
      assert %State{} = Reconciler.resolve_orphaned_divergence_attentions(state)
      assert_receive {:event, %{topic: ^resolved_topic}}, 500
    end

    test "resolves a divergence before removing an absent running ticket" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-missing-divergence.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-missing-divergence", identifier: "I-missing-divergence", state: "rework"}

      state = %State{
        running: %{
          issue.id => %{
            pid: nil,
            ref: make_ref(),
            identifier: issue.identifier,
            issue: issue,
            started_at: DateTime.utc_now(),
            control: paused_control(),
            paused_reason: :max_agent_duration
          }
        }
      }

      opened = Reconciler.report_label_divergence(state, issue)
      assert_receive {:event, %{topic: ^topic}}, 500

      removed = Reconciler.reconcile_missing_running_issue_ids(opened, [issue.id], [])

      assert_receive {:event, %{topic: ^resolved_topic}}, 500
      refute Map.has_key?(removed.running, issue.id)
    end

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
