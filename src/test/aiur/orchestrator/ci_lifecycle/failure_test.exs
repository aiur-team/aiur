defmodule Aiur.Orchestrator.CiLifecycle.FailureTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.CIApprovalStore
  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.State

  setup :ci_lifecycle_setup

  describe "CI lifecycle coordination" do
    test "failing CI queues failed-check context before resuming into rework" do
      identifier = unique_identifier("ci-failed")
      topic = "ticket.#{identifier}.ci.failed"
      recorder = start_recorder(topic)
      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "failed-head",
          pr_number: 942,
          failures: [
            %{name: "lint", result: "failure", excerpt: "lint failed"},
            %{name: "coverage", result: "failure"}
          ]
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}}
      assert_received {:recorded, 2, {:event, %{topic: ^topic}}}
      assert_received {:recorded, 3, {:agent_queue_updated, ^identifier, _item_id, false}}
      assert_received {:recorded, 4, {:resume_agent, _request_id, 101}}

      assert next.running[identifier].issue.state == "rework"
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].paused_reason == :ci_wait
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)

      assert [%{body: %{events: [event]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
      assert Enum.map(event.checks, & &1.name) == ["lint", "coverage"]
      assert event.failure_excerpt == "lint failed"
      assert event.message =~ "CI failed: lint, coverage"
    end

    test "a head that actually passed CI reworks on a later failure after handoff and reload" do
      identifier = unique_identifier("ci-failed-human-review")
      topic = "ticket.#{identifier}.ci.failed"
      recorder = start_recorder(topic)
      issue = issue(identifier, "human-review")

      waiting = %{issue | state: "ci-wait"}
      passed = poll_ci(running_state(waiting, recorder, :paused, paused_reason: :ci_wait), waiting, %{decision: :passed, head_sha: "reviewed-head", pr_number: 99})
      assert passed.running[identifier].issue.state == "in-progress"
      assert CIApprovalStore.load().passed_heads == %{identifier => "reviewed-head"}

      # The agent's review handoff and a daemon restart follow the real CI pass.
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)
      state = %{state | ci_lifecycle: Map.merge(state.ci_lifecycle, CIApprovalStore.load())}

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "reviewed-head",
          pr_number: 99,
          failures: [%{name: "lint", result: "failure", excerpt: "lint failed after handoff"}]
        })

      sync_recorder(recorder)

      assert_received {:recorded, _position, {:tracker_update, ^identifier, "rework", [expected_state: "human-review"]}}
      assert_received {:recorded, _position, {:event, %{topic: ^topic}}}
      assert_received {:recorded, _position, {:agent_queue_updated, ^identifier, _item_id, false}}
      assert_received {:recorded, _position, {:resume_agent, _request_id, 101}}
      assert next.running[identifier].issue.state == "rework"
      assert next.ci_lifecycle.approved_heads == %{}
      assert next.ci_lifecycle.passed_heads == %{}
      assert [%{body: %{events: [event]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
      assert event.failure_excerpt == "lint failed after handoff"
    end

    test "red CI on a draft in ci-wait without a worker leaves exactly rework" do
      identifier = to_string(System.unique_integer([:positive]))
      issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
      start_recorder()
      ResourceStore.reset()
      on_exit(&ResourceStore.reset/0)
      previous_token = :persistent_term.get({Aiur.GitHub.Config, :resolved_token}, :unset)
      :persistent_term.put({Aiur.GitHub.Config, :resolved_token}, "test-token")

      on_exit(fn ->
        if previous_token == :unset,
          do: :persistent_term.erase({Aiur.GitHub.Config, :resolved_token}),
          else: :persistent_term.put({Aiur.GitHub.Config, :resolved_token}, previous_token)
      end)

      labels = :ets.new(:ci_labels, [:set, :private])
      :ets.insert(labels, {:labels, ["agent:ci-wait"]})

      RecordingGitHubClient.request_with(fn request ->
        [{:labels, current}] = :ets.lookup(labels, :labels)

        next =
          case request.method do
            :get -> current
            :post -> Enum.uniq(current ++ request.body["labels"])
            :delete -> List.delete(current, request.url |> String.split("/") |> List.last() |> URI.decode())
          end

        :ets.insert(labels, {:labels, next})
        if request.method != :get, do: assert(next != [], "state writes must never leave zero labels")
        body = Enum.map(next, &%{"name" => &1})
        {:ok, %{status: 200, body: if(request.method == :get, do: %{"state" => "open", "labels" => body}, else: body)}}
      end)

      state = with_approved_head(%State{}, identifier, "reviewed-head")
      assert state.running == %{}
      next = poll_ci(state, issue, %{decision: :failed, draft?: true, head_sha: "reviewed-head", pr_number: 3095, failures: [%{name: "lint", result: "failure"}]})

      assert :ets.lookup(labels, :labels) == [{:labels, ["agent:rework"]}]
      assert next.ci_lifecycle.approved_heads == %{}
    end

    test "a stale ci-wait projection cannot rework the persisted approved head" do
      identifier = unique_identifier("ci-stale-approved-head")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}

      :ok = CIApprovalStore.save(%{identifier => "reviewed-head"}, %{})

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> then(fn state ->
          %{state | ci_lifecycle: Map.merge(state.ci_lifecycle, CIApprovalStore.load())}
        end)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "reviewed-head",
          pr_number: 99,
          failures: [%{name: "quarantined tests (non-blocking)", result: "failure"}]
        })

      sync_recorder(recorder)

      refute_received {:recorded, _position, {:tracker_update, ^identifier, "rework", _opts}}
      refute_received {:recorded, _position, {:label_removed, ^identifier, "agent:ci-wait"}}
      assert next.running[identifier].issue.state == "ci-wait"
      assert next.ci_lifecycle.approved_heads == %{identifier => "reviewed-head"}
    end

    test "a stale ci-wait projection still reworks a different head" do
      identifier = unique_identifier("ci-stale-superseded-head")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> with_approved_head(identifier, "reviewed-head")

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "pushed-head",
          pr_number: 99,
          failures: [%{name: "lint", result: "failure", excerpt: "lint failed"}]
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}}
      assert next.running[identifier].issue.state == "rework"
      assert next.ci_lifecycle.approved_heads == %{}
    end

    test "inherited human-review failures stay dismissed across repeated polls and a restart" do
      identifier = unique_identifier("ci-dismissed-human-review")
      recorder = start_recorder()
      issue = issue(identifier, "human-review")
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

      result = %{
        decision: :failed,
        head_sha: "dismissed-head",
        pr_number: 99,
        failures: [%{name: "coverage", result: "failure"}]
      }

      first = poll_ci(state, issue, result)
      assert first.ci_lifecycle.approved_heads == %{identifier => "dismissed-head"}
      assert first.ci_lifecycle.passed_heads == %{}
      repeated = poll_ci(first, issue, result)
      persisted = CIApprovalStore.load()
      assert persisted.approved_heads == %{identifier => "dismissed-head"}
      assert persisted.passed_heads == %{}
      restarted = %{state | ci_lifecycle: Map.merge(state.ci_lifecycle, persisted)}
      after_restart = poll_ci(restarted, issue, result)
      sync_recorder(recorder)

      refute_received {:recorded, _position, {:tracker_update, ^identifier, "rework", _opts}}
      assert repeated.running[identifier].issue.state == "human-review"
      assert after_restart.running[identifier].issue.state == "human-review"

      changed = poll_ci(after_restart, issue, %{result | head_sha: "new-head"})
      sync_recorder(recorder)
      assert_received {:recorded, _position, {:tracker_update, ^identifier, "rework", [expected_state: "human-review"]}}
      assert changed.running[identifier].issue.state == "rework"
    end

    test "legacy persisted review anchors are conservatively held until a real pass" do
      identifier = unique_identifier("ci-legacy-dismissal")
      recorder = start_recorder()
      issue = issue(identifier, "human-review")
      File.write!(CIApprovalStore.path_for(), Jason.encode!(%{"approved_heads" => %{identifier => "legacy-head"}}))
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)
      state = %{state | ci_lifecycle: Map.merge(state.ci_lifecycle, CIApprovalStore.load())}

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "legacy-head",
          pr_number: 99,
          failures: [%{name: "lint", result: "failure"}]
        })

      sync_recorder(recorder)
      refute_received {:recorded, _position, {:tracker_update, ^identifier, "rework", _opts}}
      assert next.running[identifier].issue.state == "human-review"
      assert next.ci_lifecycle.passed_heads == %{}
    end

    test "a CI failure on a head review has not seen still moves the ticket to rework" do
      identifier = unique_identifier("ci-new-head-human-review")
      topic = "ticket.#{identifier}.ci.failed"
      recorder = start_recorder(topic)
      issue = issue(identifier, "human-review")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> with_approved_head(identifier, "reviewed-head")

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "pushed-head",
          pr_number: 99,
          failures: [%{name: "lint", result: "failure", excerpt: "lint failed"}]
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "human-review"]}}
      assert next.running[identifier].issue.state == "rework"
      assert next.ci_lifecycle.approved_heads == %{}
    end

    test "pending CI is idempotent for an existing ci-wait ticket" do
      identifier = unique_identifier("ci-idempotent")
      recorder = start_recorder()

      issue = issue(identifier, "ci-wait")
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      next = poll_ci(armed, issue, %{decision: :pending, head_sha: "same-head"})
      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}

      # A redundant poll still caches the OCC-5 CI/PR projection without
      # changing the running entry or the already-armed fallback timer.
      assert next.running == armed.running

      assert next.ci_lifecycle.poll_cache == %{
               identifier => %{
                 decision: :pending,
                 pr_number: nil,
                 head_sha: "same-head",
                 draft?: false,
                 review_decision: nil
               }
             }

      assert Map.drop(next.ci_lifecycle, [:poll_cache, :parked_ready_alerts, :draft_stall_alerts]) ==
               Map.drop(armed.ci_lifecycle, [:poll_cache, :parked_ready_alerts, :draft_stall_alerts])
    end

    test "a pre-existing operator pause does not arm the CI fallback" do
      identifier = unique_identifier("ci-operator-paused")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state =
        running_state(issue, recorder, :paused,
          paused_reason: :operator_pause,
          blocker_pause_generation: 1,
          blocker_pause: %{blocker_identifier: "99", generation: 1},
          pending_auto_resume: %{pause_generation: 1}
        )

      next = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      sync_recorder(recorder)

      assert next.running[identifier].paused_reason == :operator_pause
      refute Map.has_key?(next.running[identifier], :blocker_pause)
      refute Map.has_key?(next.running[identifier], :pending_auto_resume)
      assert next.ci_lifecycle.rewakes == %{}
      refute_received {:recorded, _position, _message}
    end

    test "an unclassified worker pause preserves the pending CI-wait cause" do
      identifier = unique_identifier("ci-unclassified-pause")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")
      ci_wait_topic = "ticket.#{identifier}.ci.wait"
      operator_pause_topic = "ticket.#{identifier}.agent.attention.paused-operator_pause"

      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(ci_wait_topic)
      :ok = Exchange.subscribe(operator_pause_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      pending =
        issue
        |> running_state(recorder, :working, [])
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      assert_receive {:recorded, 1, {:pause_agent, request_id, 101}}, 1000
      assert pending.running[identifier].pending_pause_reason == %{request_id: request_id, reason: :ci_wait}

      MessageHandler.send_control_state(self(), issue, :paused, %{})
      assert_receive {:worker_control_state, ^identifier, :paused, payload}, 1000

      assert {:noreply, paused} =
               Orchestrator.handle_info(
                 {:worker_control_state, identifier, :paused, payload},
                 pending
               )

      assert paused.running[identifier].control.status == :paused
      assert paused.running[identifier].paused_reason == :ci_wait

      assert_receive {:event,
                      %{
                        "needs_attention" => false,
                        "severity" => "info",
                        topic: ^ci_wait_topic
                      }},
                     500

      refute_receive {:event, %{topic: ^operator_pause_topic}}, 100
    end

    test "an explicit worker pause cause overrides pending CI wait" do
      identifier = unique_identifier("ci-explicit-pause")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      pending =
        issue
        |> running_state(recorder, :working, [])
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      assert_receive {:recorded, 1, {:pause_agent, _request_id, 101}}, 1000

      assert {:noreply, paused} =
               Orchestrator.handle_info(
                 {:worker_control_state, identifier, :paused, %{kind: :usage_limit_exhausted}},
                 pending
               )

      assert paused.running[identifier].paused_reason == :usage_limit_exhausted
    end
  end
end
