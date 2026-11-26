defmodule Aiur.Orchestrator.ReconcilerIssueStateTest do
  use Aiur.TestSupport

  alias Aiur.{Alerts, Issue, TrackerIdentity}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{PauseResume, Reconciler, State}

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

        assert_receive {:pause_agent, ^request_id, 1}, 1000

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

    # #2409: a deferred authorization (the provenance fetch was held/rate-limited,
    # not a verified revocation) must NOT stop the running agent. Killing it here
    # converted a 30-second budget hold into a terminal `agent:error` via retry
    # exhaustion; the running agent stays and the next poll re-verifies once the
    # cause clears.
    test "keeps an active worker when refreshed dispatch authorization is deferred" do
      parent = self()
      identity = tracker_identity("I-authorization-deferred")

      issue = %Issue{
        id: "issue-authorization-deferred",
        identifier: "I-authorization-deferred",
        state: "in-progress",
        tracker_identity: identity,
        dispatch_authorized?: false,
        dispatch_authorization: :deferred
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
          fn _observed_identity, _lifecycle ->
            send(parent, :unexpected_membership)
            :ok
          end
        )

      refute_received :unexpected_membership
      assert Map.has_key?(result.running, issue.id)
      assert MapSet.member?(result.claimed, issue.id)
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
end
