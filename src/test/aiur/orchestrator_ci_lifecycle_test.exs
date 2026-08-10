defmodule Aiur.OrchestratorCILifecycleTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, CIApprovalStore, TrackerIdentity}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{CiLifecycle, State}

  defmodule RecordingGitHubClient do
    @recipient_key {__MODULE__, :recipient}
    @update_result_key {__MODULE__, :update_result}
    @issues_key {__MODULE__, :issues}

    def record_to(pid), do: Process.put(@recipient_key, pid)
    def return(result), do: Process.put(@update_result_key, result)
    def return_issues(issues), do: Process.put(@issues_key, issues)

    def fetch_issue_states_by_ids(issue_ids) do
      issues = Process.get(@issues_key, [])
      {:ok, Enum.filter(issues, &(&1.id in issue_ids))}
    end

    def update_issue_state(issue_id, state_name) do
      record_update(issue_id, state_name, [])
    end

    def update_issue_state(issue_id, state_name, opts) when is_list(opts) do
      record_update(issue_id, state_name, opts)
    end

    defp record_update(issue_id, state_name, opts) do
      case recipient() do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_update, issue_id, state_name, opts})
          Process.get(@update_result_key, :ok)

        _other ->
          {:error, :unscoped_test_call}
      end
    end

    defp recipient, do: Process.get(@recipient_key)
  end

  setup do
    previous_client = Application.get_env(:aiur, :github_client_module)
    previous_store_path = Application.get_env(:aiur, :ci_approval_store_path)

    store_path =
      Path.join(
        System.tmp_dir!(),
        "aiur_ci_lifecycle_#{System.unique_integer([:positive])}.json"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :github_client_module, RecordingGitHubClient)
    Application.put_env(:aiur, :ci_approval_store_path, store_path)

    on_exit(fn ->
      restore_application_env(:github_client_module, previous_client)
      restore_application_env(:ci_approval_store_path, previous_store_path)
      File.rm(store_path)
    end)

    :ok
  end

  describe "CI lifecycle coordination" do
    test "a completed runner entering CI wait is parked without a cooperative pause" do
      identifier = unique_identifier("completed-ci-wait")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :completed, [])
      ref = Process.monitor(recorder)
      next = CiLifecycle.pause_issue_for_ci_wait(state, issue)

      assert_receive {:DOWN, ^ref, :process, ^recorder, :killed}
      refute_received {:recorded, _sequence, {:pause_agent, _request_id}}

      entry = Map.fetch!(next.running, identifier)
      assert entry.control.status == :deactivated
      assert entry.paused_reason == :ci_wait
      assert entry.pid == nil
      assert entry.ref == nil
      assert entry.completed_provenance
      assert entry.completion_totals_recorded
      assert %{token: token, timer_ref: timer_ref} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(token)
      assert is_reference(timer_ref)
    end

    test "a deactivated+ci-wait entry is woken by the CI terminal event" do
      identifier = unique_identifier("deactivated-terminal-wake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, paused_reason: :ci_wait)
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)

      in_progress_issue = %{issue | state: "in-progress"}
      RecordingGitHubClient.return_issues([in_progress_issue])

      next = CiLifecycle.maybe_resume_for_ci_terminal(armed, identifier, :passed)

      assert next.running[identifier].issue.state == "in-progress"
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "pending CI writes ci-wait and waits for live-runner pause evidence" do
      identifier = unique_identifier("ci-pending")
      recorder = start_recorder()

      issue = issue(identifier, "human-review")
      started_at = DateTime.add(DateTime.utc_now(), -30, :second)
      state = running_state(issue, recorder, :working, started_at: started_at)

      next = poll_ci(state, issue, %{decision: :pending, head_sha: "pending-head"})
      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "ci-wait", [expected_state: "human-review"]}}
      assert_received {:recorded, 2, {:pause_agent, request_id, _generation}}
      assert is_integer(request_id)

      entry = Map.fetch!(next.running, identifier)

      assert entry.issue.state == "ci-wait"
      assert entry.control.status == :working
      assert entry.control.can_interrupt
      assert entry.pending_pause_reason == %{request_id: request_id, reason: :ci_wait}
      refute Map.has_key?(entry, :paused_reason)
      refute Map.has_key?(entry, :paused_at)
      assert entry.started_at == started_at
      assert MapSet.member?(next.claimed, identifier)
      assert Process.alive?(recorder)
      assert %{token: token, timer_ref: timer_ref} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(token)
      assert is_reference(timer_ref)
    end

    test "a failed tracker transition publishes nothing and leaves the runner untouched" do
      identifier = unique_identifier("ci-transition-failure")
      topic = "ticket.#{identifier}.ci.failed"
      recorder = start_recorder(topic)
      RecordingGitHubClient.return({:error, :tracker_down})

      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "failed-head",
          pr_number: 941,
          failures: [%{name: "lint", result: "failure", excerpt: "failed"}]
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}}
      refute_received {:recorded, 2, _message}

      # The OCC-5 CI/PR projection still caches even when the tracker write
      # itself fails and the transition is left untouched.
      assert next.running == state.running
      assert next.ci_lifecycle.poll_cache == %{identifier => %{decision: :failed, pr_number: 941, head_sha: "failed-head"}}
      assert Map.delete(next.ci_lifecycle, :poll_cache) == Map.delete(state.ci_lifecycle, :poll_cache)
      assert MapSet.member?(next.claimed, identifier)
    end

    test "passing CI records the head and publishes after the active-state write" do
      identifier = unique_identifier("ci-passed")
      topic = "ticket.#{identifier}.ci.passed"
      recorder = start_recorder(topic)

      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "approved-head",
          pr_number: 941
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}

      assert_received {:recorded, 2,
                       {:event,
                        %{
                          topic: ^topic,
                          source: :github,
                          head_sha: "approved-head",
                          pr_number: 941,
                          message: "CI passed for the current PR head"
                        }}}

      assert_received {:recorded, 3, {:agent_queue_updated, ^identifier, _item_id, false}}
      assert_received {:recorded, 4, {:resume_agent, _request_id, 101}}

      assert next.running[identifier].issue.state == "in-progress"
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].paused_reason == :ci_wait
      assert next.ci_lifecycle.approved_heads == %{identifier => "approved-head"}
      assert CIApprovalStore.load().approved_heads == %{identifier => "approved-head"}
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)

      assert [%{body: %{events: [event]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
      assert event.topic == topic
      assert event.message == "CI passed for the current PR head"
    end

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

    test "a replayed CI failure for the reviewed head keeps the ticket in human review" do
      identifier = unique_identifier("ci-replay-human-review")
      recorder = start_recorder()
      issue = issue(identifier, "human-review")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> with_approved_head(identifier, "reviewed-head")

      failure = %{
        decision: :failed,
        head_sha: "reviewed-head",
        pr_number: 99,
        failures: [%{name: "lint", result: "failure", excerpt: "inherited lint failure"}]
      }

      # Each Aiur restart re-delivers the same historical result for the same
      # head; none of them may override the operator-approved handoff.
      next = Enum.reduce(1..3, state, fn _replay, acc -> poll_ci(acc, issue, failure) end)
      sync_recorder(recorder)

      refute_received {:recorded, _position, {:tracker_update, ^identifier, "rework", _opts}}
      assert next.running[identifier].issue.state == "human-review"
      assert next.ci_lifecycle.approved_heads == %{identifier => "reviewed-head"}
    end

    test "a stale ci-wait projection cannot rework the persisted approved head" do
      identifier = unique_identifier("ci-stale-approved-head")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

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

    test "a CI failure observed after a dismissed-failure handoff anchors the reviewed head" do
      identifier = unique_identifier("ci-dismissed-human-review")
      recorder = start_recorder()
      issue = issue(identifier, "human-review")

      # The #99 shape: CI never passed, the operator dismissed the inherited
      # failures, and the agent flipped the label, so no head was ever approved.
      state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "dismissed-head",
          pr_number: 99,
          failures: [%{name: "coverage", result: "failure"}]
        })

      sync_recorder(recorder)

      refute_received {:recorded, _position, {:tracker_update, ^identifier, "rework", _opts}}
      assert next.running[identifier].issue.state == "human-review"
      assert next.ci_lifecycle.approved_heads == %{identifier => "dismissed-head"}
      assert CIApprovalStore.load().approved_heads == %{identifier => "dismissed-head"}
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
               identifier => %{decision: :pending, pr_number: nil, head_sha: "same-head"}
             }

      assert Map.delete(next.ci_lifecycle, :poll_cache) ==
               Map.delete(armed.ci_lifecycle, :poll_cache)
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

    test "a matching fallback token revalidates, queues one-check guidance, and resumes" do
      identifier = unique_identifier("ci-rewake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      assert_received {:recorded, 2, {:agent_queue_updated, ^identifier, _item_id, false}}
      assert_received {:recorded, 3, {:resume_agent, request_id, 101}}
      assert is_integer(request_id)

      assert next.running[identifier].issue.state == "in-progress"
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].paused_reason == :ci_wait
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)

      assert [%{body: %{events: [event]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
      assert event.topic == "ticket.#{identifier}.ci.rewake"
      assert event.source == :system
      assert event.message =~ "Check CI once"
      assert event.message =~ "return to agent:ci-wait"
    end

    test "stale fallback tokens cannot wake a CI-wait runner" do
      identifier = unique_identifier("ci-stale-rewake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      issue_fetcher = fn _ids -> flunk("stale token must not fetch tracker state") end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, make_ref(), issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert next == armed
      refute_received {:recorded, _position, _message}
    end

    test "a failed fallback transition replaces the expired timer token" do
      identifier = unique_identifier("ci-rewake-retry")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")
      RecordingGitHubClient.return({:error, :tracker_down})

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      expired_token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, expired_token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      refute_received {:recorded, _position, {:resume_agent, _request_id}}
      assert %{token: replacement_token} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(replacement_token)
      refute replacement_token == expired_token
      assert next.running[identifier].control.status == :paused
    end

    test "fallback timeout does not wake a freshly operator-paused ticket" do
      identifier = unique_identifier("ci-rewake-paused")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | paused: true}

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].issue.paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "fallback timeout does not wake a ticket routed away from this worker" do
      identifier = unique_identifier("ci-rewake-routed-away")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | assigned_to_worker: false}

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "a deactivated runner entering CI wait gets paused_reason and fallback rewake armed" do
      identifier = unique_identifier("deactivated-ci-wait")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, [])
      next = CiLifecycle.pause_issue_for_ci_wait(state, issue)

      entry = Map.fetch!(next.running, identifier)
      assert entry.control.status == :deactivated
      assert entry.paused_reason == :ci_wait
      assert %{token: token, timer_ref: timer_ref} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(token)
      assert is_reference(timer_ref)
    end

    test "a deactivated ci-wait entry is recovered by the fallback rewake" do
      identifier = unique_identifier("deactivated-rewake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [%{issue | state: "ci-wait"}]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "deactivated ci-wait rewake does not wake when issue is no longer in ci-wait state" do
      identifier = unique_identifier("deactivated-rewake-state-guard")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      transitioned_issue = %{issue | state: "in-progress"}
      issue_fetcher = fn [^identifier] -> {:ok, [transitioned_issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :deactivated
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "deactivated ci-wait rewake does not wake when issue is operator-paused" do
      identifier = unique_identifier("deactivated-rewake-paused-guard")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | paused: true}

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :deactivated
      assert next.running[identifier].issue.paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "deactivated ci-wait rewake does not wake when issue is routed away from this worker" do
      identifier = unique_identifier("deactivated-rewake-routed-guard")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | assigned_to_worker: false}

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :deactivated
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "tracker recording ignores unrelated process traffic" do
      recorder = start_recorder()

      assert {:error, :unscoped_test_call} =
               Task.async(fn -> RecordingGitHubClient.update_issue_state("42", "rework") end)
               |> Task.await()

      sync_recorder(recorder)
      refute_received {:recorded, _position, _message}
    end
  end

  defp poll_ci(state, issue, result) do
    next =
      CiLifecycle.poll_github_ci(state,
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
        ci_poller: fn [target], _opts ->
          assert target == issue.identifier
          {:ok, %{results: [Map.put(result, :target, target)], errors: []}}
        end
      )

    maybe_route_ci_terminal(next, issue, result)
  end

  defp maybe_route_ci_terminal(state, issue, %{decision: outcome}) when outcome in [:passed, :failed] do
    handoff_state = if outcome == :passed, do: "in-progress", else: "rework"

    case get_in(state.running, [issue.id, :issue, Access.key(:state)]) do
      ^handoff_state ->
        current_issue = %{issue | state: handoff_state}
        RecordingGitHubClient.return_issues([current_issue])

        CiLifecycle.maybe_resume_for_ci_terminal(state, issue.identifier, outcome)

      _ ->
        state
    end
  end

  defp maybe_route_ci_terminal(state, _issue, _result), do: state

  defp with_approved_head(%State{} = state, identifier, head_sha) do
    %{state | ci_lifecycle: %{state.ci_lifecycle | approved_heads: %{identifier => head_sha}}}
  end

  defp running_state(issue, pid, status, attrs) do
    entry =
      %{
        pid: pid,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        control: %{
          status: status,
          can_interrupt: true,
          safe_checkpoints: [:notification],
          application_confirmation: :confirmed,
          generation: 101,
          version: 0
        }
      }
      |> Map.merge(Map.new(attrs))

    %State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  defp issue(identifier, state) do
    %Issue{
      id: identifier,
      identifier: identifier,
      state: state,
      title: "Characterize CI lifecycle",
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "I_kwDO#{identifier}",
        identifier: "101",
        reason: nil
      }
    }
  end

  defp unique_identifier(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp start_recorder(topic \\ nil) do
    test_pid = self()

    recorder =
      spawn(fn ->
        if is_binary(topic), do: Exchange.subscribe(topic)
        send(test_pid, {:recorder_ready, self()})
        record_messages(test_pid, 1)
      end)

    assert_receive {:recorder_ready, ^recorder}, 2_000
    RecordingGitHubClient.record_to(recorder)
    on_exit(fn -> if Process.alive?(recorder), do: Process.exit(recorder, :kill) end)
    recorder
  end

  defp record_messages(test_pid, position) do
    receive do
      {:sync_recorder, reply_to, ref} ->
        send(reply_to, {:recorder_synced, ref})
        record_messages(test_pid, position)

      message ->
        send(test_pid, {:recorded, position, message})
        record_messages(test_pid, position + 1)
    end
  end

  defp sync_recorder(recorder) do
    ref = make_ref()
    send(recorder, {:sync_recorder, self(), ref})
    assert_receive {:recorder_synced, ^ref}, 2_000
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
