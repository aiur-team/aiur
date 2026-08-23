defmodule Aiur.OrchestratorCILifecycleTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, CIApprovalStore, PollCadence, TrackerIdentity}
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

    def hydrate_blocked_by(issue), do: {:ok, issue}

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
    test "a delivered (displaced) result is inert: no transition, no cache projection" do
      identifier = unique_identifier("ci-delivered-inert")
      issue = issue(identifier, "ci-wait")
      state = %State{}

      next = poll_ci(state, issue, %{delivered: true, head_sha: "head-77", pr_number: 77})

      # A target the batch displaced because a webhook delivery answered it
      # must not move state and must not cache a projection: the real verdict
      # comes from the next non-displaced read (R10 — a CI verdict is never
      # answered from a held body at any age).
      assert next.ci_lifecycle.poll_cache == %{}
      assert next.claimed == MapSet.new()
    end

    test "a locally held GraphQL batch skips the REST fallback cycle" do
      issue = issue(unique_identifier("locally-held-ci-batch"), "ci-wait")
      state = %State{}

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_batch_fetcher: fn [_target], _opts ->
            {:error, {:aiur, :locally_held, %{resource: "graphql", reset_at: DateTime.add(DateTime.utc_now(), 45, :second)}}}
          end,
          request_fun: fn _request -> flunk("local GraphQL hold must not fan out to REST") end,
          token: "test-gh-token",
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )

      assert next.ci_lifecycle.poll_cache == %{}
    end

    test "a genuine GraphQL batch failure retains the REST fallback cycle" do
      identifier = unique_identifier("failed-ci-batch")
      issue = issue(identifier, "ci-wait")
      parent = self()

      request_fun = fn %{url: url} ->
        send(parent, {:rest_request, url})

        cond do
          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 71,
                   "head" => %{"ref" => "aiur/#{identifier}", "sha" => "current-sha"},
                   "base" => %{"ref" => "main"}
                 }
               ]
             }}

          String.contains?(url, "/check-runs?") ->
            {:ok,
             %{
               status: 200,
               body: %{"check_runs" => [%{"name" => "lint", "status" => "completed", "conclusion" => "success"}]}
             }}

          String.ends_with?(url, "/status") ->
            {:ok, %{status: 200, body: %{"state" => "pending", "total_count" => 0, "statuses" => []}}}
        end
      end

      next =
        CiLifecycle.poll_github_ci(%State{},
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_batch_fetcher: fn [_target], _opts -> {:error, {:github, :rate_limited, %{status: 429}}} end,
          request_fun: request_fun,
          token: "test-gh-token",
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )

      assert_received {:rest_request, _url}
      assert Map.has_key?(next.ci_lifecycle.poll_cache, identifier)
    end

    test "CI pruning preserves tracker list caches shared with other poll phases" do
      state = %State{
        ci_lifecycle: %{
          %State{}.ci_lifecycle
          | poll_cache: %{
              "stale-target" => %{head_sha: "old"},
              issue_list_cache: %{pages: %{1 => %{etag: "ci-v1"}}},
              candidate_list_cache: %{pages: %{1 => %{etag: "candidates-v1"}}}
            }
        }
      }

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end
        )

      assert next.ci_lifecycle.poll_cache == %{
               issue_list_cache: %{pages: %{1 => %{etag: "ci-v1"}}},
               candidate_list_cache: %{pages: %{1 => %{etag: "candidates-v1"}}}
             }
    end

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

      assert next.ci_lifecycle.poll_cache == %{
               identifier => %{
                 decision: :failed,
                 pr_number: 941,
                 head_sha: "failed-head",
                 draft?: false,
                 review_decision: nil
               }
             }

      assert next.ci_lifecycle.draft_stall_alerts == MapSet.new()

      assert Map.drop(next.ci_lifecycle, [:poll_cache, :parked_ready_alerts, :draft_stall_alerts]) ==
               Map.drop(state.ci_lifecycle, [:poll_cache, :parked_ready_alerts, :draft_stall_alerts])

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

    test "alerts once when an approved, green PR is still a draft (#1974)" do
      identifier = unique_identifier("ci-draft-stall")
      alert_topic = "ticket.#{identifier}.pr.draft_approved_green"
      recorder = start_recorder(alert_topic)
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)
      issue = issue(identifier, "human-review")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)

      result = %{
        decision: :passed,
        head_sha: "stalled-head",
        pr_number: 941,
        draft?: true,
        review_decision: "APPROVED"
      }

      next = poll_ci(state, issue, result, alert_emitter: emitter)
      sync_recorder(recorder)

      # Approved + green + draft is always wrong: the daemon alerts so the
      # stall is loud instead of an indistinguishable BLOCKED.
      assert_received {:parked_alert, ^ref, ^alert_topic, alert_opts}
      assert Keyword.get(alert_opts, :needs_attention) == true

      # The projection records draft state so the Executor queue surfaces DRAFT.
      assert next.ci_lifecycle.poll_cache == %{
               identifier => %{
                 decision: :passed,
                 pr_number: 941,
                 head_sha: "stalled-head",
                 draft?: true,
                 review_decision: "APPROVED"
               }
             }

      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)

      # Re-polling the identical stalled head must not re-alert every cycle.
      _again = poll_ci(next, issue, result, alert_emitter: emitter)
      sync_recorder(recorder)
      refute_received {:parked_alert, ^ref, ^alert_topic, _opts}
    end

    test "does not alert for a ready (non-draft) green PR" do
      identifier = unique_identifier("ci-draft-ready")
      alert_topic = "ticket.#{identifier}.pr.draft_approved_green"
      recorder = start_recorder(alert_topic)
      issue = issue(identifier, "human-review")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)

      _next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "ready-head",
          pr_number: 942,
          draft?: false,
          review_decision: "APPROVED"
        })

      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^alert_topic}}}
    end

    test "does not alert for an approved draft that is still pending CI" do
      identifier = unique_identifier("ci-draft-pending")
      alert_topic = "ticket.#{identifier}.pr.draft_approved_green"
      recorder = start_recorder(alert_topic)
      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)

      _next =
        poll_ci(state, issue, %{
          decision: :pending,
          head_sha: "pending-head",
          pr_number: 943,
          draft?: true,
          review_decision: "APPROVED"
        })

      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^alert_topic}}}
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

  describe "CI poll :ci-cadence throttle" do
    setup do
      PollCadence.forget_effective_interval_ms()
      on_exit(&PollCadence.forget_effective_interval_ms/0)
      :ok
    end

    # The throttle returns the state untouched — no issue fetch, no GraphQL
    # poll — so the injected fetchers/pollers must never fire. This is the
    # whole point: an expensive CI read must not run at the dispatch rate once
    # an operator gives `:ci` its own (wider) cadence.
    test "skips the poll while within the published ci cadence" do
      PollCadence.publish_effective_interval_ms(300_000, class: :ci)
      state = %State{last_ci_poll_started_at_ms: System.monotonic_time(:millisecond)}

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn _states -> flunk("throttled poll must not fetch issues") end,
          ci_poller: fn _targets, _opts -> flunk("throttled poll must not poll") end,
          token: "test-gh-token"
        )

      assert next == state
    end

    # Like the comment poll gate, a CI poll is never throttled before the
    # dispatcher has published a live `:ci` cadence (cold start, harnesses): the
    # first read of a freshly in-flight PR must not be held back by a cadence
    # nobody has observed yet.
    test "a recent poll is not throttled before the ci cadence is published" do
      PollCadence.forget_effective_interval_ms()
      issue = issue(unique_identifier("ci-unthrottled"), "ci-wait")
      state = %State{last_ci_poll_started_at_ms: System.monotonic_time(:millisecond)}

      next = poll_ci(state, issue, %{status: "pending", head_sha: "head-1", pr_number: 1})

      assert next.last_ci_poll_started_at_ms != nil
      assert is_map(next.ci_lifecycle.poll_cache)
    end
  end

  describe "parked-ready recovery alert" do
    defp capture_alert_emitter(test_pid, ref) do
      fn topic, opts ->
        send(test_pid, {:parked_alert, ref, topic, opts})
        :ok
      end
    end

    defp parked_observation(overrides \\ %{}) do
      Map.merge(
        %{
          decision: :passed,
          pr_number: 77,
          head_sha: "parked-head",
          draft?: false,
          review_decision: "APPROVED",
          mergeable: "MERGEABLE",
          merge_state_status: "BLOCKED",
          auto_merge_request: nil,
          merge_queue_entry: nil
        },
        overrides
      )
    end

    test "emits a needs-attention parked-ready alert for an approved ready mergeable unarmed PR" do
      identifier = unique_identifier("parked-ready-emit")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()

      next = poll_ci(state, issue, parked_observation(), alert_emitter: capture_alert_emitter(self(), ref))
      topic = "ticket.#{identifier}.pr.parked_ready"

      assert_received {:parked_alert, ^ref, ^topic, opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :central) == true
      assert MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end

    test "does not re-emit for a still-parked PR already tracked" do
      identifier = unique_identifier("parked-ready-dedupe")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, parked_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.parked_ready_alerts, identifier)

      second = poll_ci(first, issue, parked_observation(), alert_emitter: emitter)

      assert_received {:parked_alert, ^ref, _topic, _opts}
      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert second.ci_lifecycle.parked_ready_alerts == first.ci_lifecycle.parked_ready_alerts
    end

    test "resolves the alert once the PR reports an auto-merge request" do
      identifier = unique_identifier("parked-ready-resolve")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, parked_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.parked_ready_alerts, identifier)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      armed = parked_observation(%{auto_merge_request: %{"enabledAt" => "2026-08-13T20:00:00Z"}})
      next = poll_ci(first, issue, armed, alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.parked_ready.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, resolve_opts}
      assert Keyword.get(resolve_opts, :needs_attention) == false
      refute MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end

    test "does not emit or clear on a transient poll failure" do
      identifier = unique_identifier("parked-ready-unknown")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()

      result = %{decision: :pending, pending_reason: :ci_lookup_unavailable, error: :test}
      next = poll_ci(state, issue, result, alert_emitter: capture_alert_emitter(self(), ref))

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert next.ci_lifecycle.parked_ready_alerts == MapSet.new()
    end

    test "resolves the alert when the open PR is no longer visible" do
      identifier = unique_identifier("parked-ready-gone")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, parked_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.parked_ready_alerts, identifier)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      gone = %{decision: :pending, pending_reason: :open_pr_not_yet_visible}
      next = poll_ci(first, issue, gone, alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.parked_ready.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, _resolve_opts}
      refute MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end

    test "resolves the alert when the issue leaves the poll set" do
      identifier = unique_identifier("parked-ready-depart")
      issue = issue(identifier, "human-review")
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      state =
        running_state(issue, self(), :working, [])
        |> Map.update!(:ci_lifecycle, &Map.put(&1, :parked_ready_alerts, MapSet.new([identifier])))

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
          alert_emitter: emitter,
          parked_ready_alert_loader: fn -> MapSet.new() end
        )

      resolved_topic = "ticket.#{identifier}.pr.parked_ready.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, _resolve_opts}
      refute MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end
  end

  describe "approved green draft alert lifecycle" do
    defp draft_stall_observation(overrides \\ %{}) do
      Map.merge(
        %{
          decision: :passed,
          pr_number: 941,
          head_sha: "stalled-head",
          draft?: true,
          review_decision: "APPROVED"
        },
        overrides
      )
    end

    test "resolves the attention when the PR becomes ready" do
      identifier = unique_identifier("draft-stall-resolve")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.draft_stall_alerts, identifier)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      next = poll_ci(first, issue, draft_stall_observation(%{draft?: false}), alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.draft_approved_green.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, resolve_opts}
      assert Keyword.get(resolve_opts, :needs_attention) == false
      refute MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "keeps the attention latched across an incomplete poll" do
      identifier = unique_identifier("draft-stall-transient")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      transient = %{decision: :pending, pending_reason: :ci_lookup_unavailable, error: :test}
      second = poll_ci(first, issue, transient, alert_emitter: emitter)
      assert second.ci_lifecycle.poll_cache[identifier].draft? == true
      assert second.ci_lifecycle.poll_cache[identifier].review_decision == "APPROVED"

      third = poll_ci(second, issue, draft_stall_observation(), alert_emitter: emitter)

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(third.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "keeps the attention latched when REST fallback cannot observe approval" do
      identifier = unique_identifier("draft-stall-rest-fallback")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      fallback = draft_stall_observation(%{review_decision: nil})
      next = poll_ci(first, issue, fallback, alert_emitter: emitter)

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "keeps the attention latched through a transient branch-list miss" do
      identifier = unique_identifier("draft-stall-not-visible")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      transient = %{decision: :pending, pending_reason: :open_pr_not_yet_visible}
      next = poll_ci(first, issue, transient, alert_emitter: emitter)

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "resolves and clears the draft projection when a visible PR disappears" do
      identifier = unique_identifier("draft-stall-gone")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      gone = %{decision: :pending, pending_reason: :open_pr_no_longer_visible}
      next = poll_ci(first, issue, gone, alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.draft_approved_green.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, _opts}
      refute MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
      assert next.ci_lifecycle.poll_cache[identifier].draft? == false
      assert next.ci_lifecycle.poll_cache[identifier].review_decision == nil
    end

    test "keeps the attention active while the ticket temporarily leaves the poll set" do
      identifier = unique_identifier("draft-stall-depart")
      issue = issue(identifier, "human-review")
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      state =
        running_state(issue, self(), :working, [])
        |> Map.update!(:ci_lifecycle, &Map.put(&1, :draft_stall_alerts, MapSet.new([identifier])))

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
          alert_emitter: emitter,
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)

      ready_issue = issue(identifier, "human-review")

      resolved =
        poll_ci(next, ready_issue, draft_stall_observation(%{draft?: false}), alert_emitter: emitter)

      resolved_topic = "ticket.#{identifier}.pr.draft_approved_green.resolved"
      assert_received {:parked_alert, ^ref, ^resolved_topic, _opts}
      refute MapSet.member?(resolved.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "seeds an active attention after restart instead of re-emitting it" do
      identifier = unique_identifier("draft-stall-restart")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()

      next =
        poll_ci(state, issue, draft_stall_observation(),
          alert_emitter: capture_alert_emitter(self(), ref),
          draft_stall_alert_loader: fn -> MapSet.new([identifier]) end
        )

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end
  end

  defp poll_ci(state, issue, result, opts \\ []) do
    next =
      CiLifecycle.poll_github_ci(
        state,
        Keyword.merge(
          [
            # Hermetic: parked-ready restart dedupe seeds from the durable
            # alert ledger; tests never read the real ledger.
            parked_ready_alert_loader: fn -> MapSet.new() end,
            draft_stall_alert_loader: fn -> MapSet.new() end,
            ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
            ci_poller: fn [target], _opts ->
              assert target == issue.identifier
              {:ok, %{results: [Map.put(result, :target, target)], errors: []}}
            end
          ],
          opts
        )
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
