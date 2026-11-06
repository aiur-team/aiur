defmodule Aiur.Orchestrator.ReconcilerRecoveryTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Reconciler, State}

  describe "blocking Command running-agent stop (#1965)" do
    test "stops a running agent when its ticket opens a blocking Command" do
      parent = self()
      identity = tracker_identity("I-blocked-running")

      issue = %Issue{
        id: "issue-blocked-running",
        identifier: "I-blocked-running",
        state: "in-progress",
        tracker_identity: identity
      }

      state = %State{
        blocked_ticket_ids: MapSet.new([issue.id]),
        running: %{
          issue.id => %{
            pid: nil,
            ref: make_ref(),
            identifier: issue.identifier,
            issue: issue,
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue.id])
      }

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

    test "does not stop a running agent when the blocked set is unknown or the store is unavailable" do
      for blocked_ticket_ids <- [nil, :unavailable, MapSet.new(["other-issue"])] do
        issue = %Issue{
          id: "issue-stays-running",
          identifier: "I-stays-running",
          state: "in-progress"
        }

        state = %State{
          blocked_ticket_ids: blocked_ticket_ids,
          running: %{
            issue.id => %{
              pid: nil,
              ref: make_ref(),
              identifier: issue.identifier,
              issue: issue,
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue.id])
        }

        result =
          Reconciler.reconcile_issue_state(
            issue,
            state,
            MapSet.new(["in-progress"]),
            MapSet.new(),
            fn _identity, _lifecycle -> :ok end
          )

        assert Map.has_key?(result.running, issue.id),
               "a running agent must survive blocked_ticket_ids=#{inspect(blocked_ticket_ids)}"
      end
    end
  end

  describe "maybe_reactivate_or_refresh/2 before_run_failure recovery" do
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
        control: paused_control(),
        paused_reason: :before_run_failure
      }

      state = %State{running: %{"issue-brf" => entry}, max_concurrent_agents: 10}

      result = Reconciler.maybe_reactivate_or_refresh(state, issue)

      # The parked agent is blocked in AgentRunner.wait_for_before_run_resume/3;
      # a transient hook failure must self-heal by delivering the resume signal
      # to its live pid, not sit paused forever.
      assert_receive {:resume_agent, request_id, 1}, 1000

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

    # #7543: the pause used to be silent. An Executor only found it by grepping
    # the daemon log; it must raise one attention alert naming the ticket and
    # the reason, and not repeat it on every later poll.
    test "gives up with one needs-attention alert naming the ticket and the reason" do
      Publisher.set_tracked_fn(fn _ -> true end)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{
        id: "issue-brf-alert",
        identifier: "issue-brf-alert",
        state: "rework",
        tracker_identity: tracker_identity("I-before-run-failure-alert")
      }

      workspace = Path.join(Aiur.TestSupport.tmp_root!("before-run-alert"), "issue-brf-alert")
      File.mkdir_p!(Path.join(workspace, "logs"))

      File.write!(
        Path.join(workspace, "logs/agent.ndjson"),
        Jason.encode!(%{
          "event" => "worker_paused",
          "last_message" => "wip_preservation_failed: uncommitted work could not be saved, so the dirty workspace was kept"
        }) <> "\n"
      )

      entry = %{
        pid: self(),
        identifier: "issue-brf-alert",
        issue: issue,
        control: paused_control(),
        paused_reason: :before_run_failure,
        workspace_path: workspace
      }

      state = %State{running: %{"issue-brf-alert" => entry}, max_concurrent_agents: 10}
      topic = "ticket.issue-brf-alert.agent.attention.before_run_resume_exhausted"
      :ok = Exchange.subscribe(topic)

      final_state =
        Enum.reduce(1..20, state, fn _poll, acc ->
          acc = Reconciler.maybe_reactivate_or_refresh(acc, issue)

          receive do
            {:resume_agent, request_id, 1} ->
              {:noreply, resumed_state} =
                Orchestrator.handle_info(
                  {:worker_control_state, "issue-brf-alert", :working, %{request_id: request_id, generation: 1}},
                  acc
                )

              current = resumed_state.running["issue-brf-alert"]

              reparked =
                current
                |> put_in([:control, :status], :paused)
                |> Map.put(:paused_reason, :before_run_failure)

              %{resumed_state | running: Map.put(resumed_state.running, "issue-brf-alert", reparked)}
          after
            0 -> acc
          end
        end)

      assert_receive {:event, %{"needs_attention" => true, topic: ^topic} = event}, 1_000
      assert event["message"] =~ "issue-brf-alert"
      assert event["message"] =~ "wip_preservation_failed"
      assert event["message"] =~ "before_run"
      assert event["reason"] == event["message"]

      # The alert opens once; later polls refresh the entry without re-alerting.
      refute_receive {:event, %{topic: ^topic}}, 200
      assert get_in(final_state.running["issue-brf-alert"], [:before_run_resume_exhausted]) == true
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
end
