Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RetryEngine.CapacityAndScheduleTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  import Aiur.RetryEngineFixture, only: [tracker_identity: 1]

  test "slow retry poll runs outside owner and a released claim rejects its late result" do
    name = {__MODULE__, make_ref()}
    :yes = :global.register_name(name, self())
    on_exit(fn -> :global.unregister_name(name) end)
    issue = %Issue{id: "slow-retry", identifier: "MT-SLOW", state: "in-progress", title: "Slow retry"}
    state = %State{snapshot_key: {:global, name}, claimed: MapSet.new([issue.id]), max_concurrent_agents: 16, effective_concurrent_agents: 16}
    parent = self()

    assert {:noreply, next} =
             RetryEngine.handle_retry_issue(state, issue.id, 1, %{identifier: issue.identifier},
               ensure_tracker_preflight_fun: fn current -> {:ok, current} end,
               fetch_candidate_issues_fun: fn ->
                 send(parent, {:retry_fetch_started, self()})

                 receive do
                   :finish_retry_fetch -> {:ok, [issue]}
                 end
               end,
               dispatch_fun: fn _, _, _, _, _ -> flunk("released claim must not dispatch") end
             )

    receive_barrier({:retry_fetch_started, worker})
    assert worker != self()
    ref = next.tracker_tasks |> Map.keys() |> hd()
    current = %{next | claimed: MapSet.new(["other-ticket"])}
    send(worker, :finish_retry_fetch)
    receive_barrier({^ref, result})
    assert {:handled, applied} = TrackerTasks.result(current, ref, result)
    assert applied.claimed == MapSet.new(["other-ticket"])
    assert applied.running == %{}
    assert applied.retry_attempts == %{}
  end

  describe "retry capacity precondition" do
    test "a saturated retry cycle does not re-authorize the candidate set" do
      issue = %Issue{id: "issue-waiting", identifier: "MT-WAITING", state: "in-progress", title: "Waiting retry"}
      parent = self()

      running =
        Map.new(1..16, fn index ->
          {"running-#{index}", %{control: %{status: :working}}}
        end)

      state = %State{
        max_concurrent_agents: 16,
        effective_concurrent_agents: 16,
        running: running,
        claimed: MapSet.new([issue.id])
      }

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue(
                 state,
                 issue.id,
                 2,
                 %{identifier: issue.identifier, worker_host: nil},
                 ensure_tracker_preflight_fun: fn current_state -> {:ok, current_state} end,
                 fetch_candidate_issues_fun: fn ->
                   Enum.each(1..25, fn candidate ->
                     send(parent, {:dispatch_authorization, candidate})
                   end)

                   {:ok, [issue]}
                 end
               )

      refute_received {:dispatch_authorization, _candidate}
      assert %{error: "no available orchestrator slots", retry_token: retry_token} = next_state.retry_attempts[issue.id]
      Process.cancel_timer(next_state.retry_attempts[issue.id].timer_ref)
      assert is_reference(retry_token)
    end

    test "state saturation is resolved before candidate authorization" do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        max_concurrent_agents: 16,
        max_concurrent_agents_by_state: %{"in-progress" => 1}
      )

      issue = %Issue{id: "issue-state-waiting", identifier: "MT-STATE", state: "in-progress", title: "State wait"}
      parent = self()

      state = %State{
        max_concurrent_agents: 16,
        effective_concurrent_agents: 16,
        running: %{
          "running-state" => %{
            issue: %Issue{id: "running-state", identifier: "MT-RUNNING", state: "in-progress"},
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue.id])
      }

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue(
                 state,
                 issue.id,
                 2,
                 %{identifier: issue.identifier, issue_state: issue.state, worker_host: nil},
                 ensure_tracker_preflight_fun: fn current_state ->
                   send(parent, :tracker_preflight)
                   {:ok, current_state}
                 end,
                 fetch_candidate_issues_fun: fn ->
                   send(parent, :candidate_fetch)
                   {:ok, [issue]}
                 end
               )

      refute_received :tracker_preflight
      refute_received :candidate_fetch
      assert %{error: "no available orchestrator slots"} = next_state.retry_attempts[issue.id]
      Process.cancel_timer(next_state.retry_attempts[issue.id].timer_ref)
    end

    test "worker-host saturation is resolved before candidate authorization" do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        max_concurrent_agents: 16,
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-worker-waiting", identifier: "MT-WORKER", state: "in-progress", title: "Worker wait"}
      parent = self()

      state = %State{
        max_concurrent_agents: 16,
        effective_concurrent_agents: 16,
        running: %{
          "running-worker" => %{
            issue: %Issue{id: "running-worker", identifier: "MT-RUNNING", state: "todo"},
            worker_host: "worker-a",
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue.id])
      }

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue(
                 state,
                 issue.id,
                 2,
                 %{identifier: issue.identifier, issue_state: issue.state, worker_host: "worker-a"},
                 ensure_tracker_preflight_fun: fn current_state ->
                   send(parent, :tracker_preflight)
                   {:ok, current_state}
                 end,
                 fetch_candidate_issues_fun: fn ->
                   send(parent, :candidate_fetch)
                   {:ok, [issue]}
                 end
               )

      refute_received :tracker_preflight
      refute_received :candidate_fetch
      assert %{error: "no available orchestrator slots"} = next_state.retry_attempts[issue.id]
      Process.cancel_timer(next_state.retry_attempts[issue.id].timer_ref)
    end

    test "a global pause stops retry-driven tracker and dispatch-authorization traffic" do
      issue = %Issue{id: "issue-paused", identifier: "MT-PAUSED", state: "in-progress", title: "Paused retry"}
      parent = self()

      state = %State{
        globally_paused: true,
        max_concurrent_agents: 16,
        effective_concurrent_agents: 16,
        claimed: MapSet.new([issue.id])
      }

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue(
                 state,
                 issue.id,
                 2,
                 %{identifier: issue.identifier, worker_host: nil},
                 ensure_tracker_preflight_fun: fn current_state ->
                   send(parent, :tracker_preflight)
                   {:ok, current_state}
                 end,
                 fetch_candidate_issues_fun: fn ->
                   send(parent, :candidate_fetch)
                   {:ok, [issue]}
                 end
               )

      refute_received :tracker_preflight
      refute_received :candidate_fetch
      assert %{error: "no available orchestrator slots"} = next_state.retry_attempts[issue.id]
      Process.cancel_timer(next_state.retry_attempts[issue.id].timer_ref)
    end
  end

  describe "agent:retrying reason label" do
    setup do
      previous = for key <- [:memory_tracker_issues, :memory_tracker_recipient], do: {key, Application.fetch_env(:aiur, key)}

      on_exit(fn ->
        for {key, value} <- previous do
          case value do
            {:ok, v} -> Application.put_env(:aiur, key, v)
            :error -> Application.delete_env(:aiur, key)
          end
        end
      end)

      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "r-1", identifier: "r-1", state: "in-progress"}])
      Application.put_env(:aiur, :memory_tracker_recipient, self())
      :ok
    end

    test "a failure back-off sets the label and its retry fire clears it; a continuation retry writes nothing" do
      continuation = RetryEngine.schedule_issue_retry(%State{}, "r-1", 1, %{identifier: "r-1", delay_type: :continuation})
      Process.cancel_timer(continuation.retry_attempts["r-1"].timer_ref)
      refute_received {:memory_tracker_add_label, "r-1", _}

      {:ok, attempt, metadata, _popped} =
        RetryEngine.pop_retry_attempt_state(continuation, "r-1", continuation.retry_attempts["r-1"].retry_token)

      RetryEngine.handle_retry_issue(%State{}, "r-1", attempt, metadata, ensure_tracker_preflight_fun: fn s -> {:error, :skip, s} end)
      refute_received {:memory_tracker_remove_label, "r-1", _}

      failed = RetryEngine.schedule_issue_retry(%State{}, "r-1", 1, %{identifier: "r-1", error: "agent exited: boom"})
      Process.cancel_timer(failed.retry_attempts["r-1"].timer_ref)
      assert_received {:memory_tracker_add_label, "r-1", "agent:retrying"}

      {:ok, attempt, metadata, _popped} = RetryEngine.pop_retry_attempt_state(failed, "r-1", failed.retry_attempts["r-1"].retry_token)
      RetryEngine.handle_retry_issue(%State{}, "r-1", attempt, metadata, ensure_tracker_preflight_fun: fn s -> {:error, :skip, s} end)
      assert_received {:memory_tracker_remove_label, "r-1", "agent:retrying"}
    end
  end

  describe "schedule_issue_retry/4" do
    test "stores identity supplied for a newly scheduled retry" do
      identity = tracker_identity("repo#new")
      open_pr_fetcher = fn _ -> {:ok, %{head: %{sha: "new-head"}}} end
      commit_ci_status_fetcher = fn _ -> {:ok, %{check_runs: [], commit_status: %{state: "success"}}} end

      next =
        RetryEngine.schedule_issue_retry(%State{}, "issue-new", 1, %{
          identifier: "repo#new",
          tracker_identity: identity,
          priority: 1,
          issue_state: "in-progress",
          open_pr_fetcher: open_pr_fetcher,
          commit_ci_status_fetcher: commit_ci_status_fetcher,
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-new"]
      assert retry.tracker_identity == identity
      assert retry.priority == 1
      assert retry.issue_state == "in-progress"
      refute Map.has_key?(retry, :open_pr_fetcher)
      refute Map.has_key?(retry, :commit_ci_status_fetcher)
      Process.cancel_timer(retry.timer_ref)
    end

    test "retains the prior identity across a retry/session reschedule" do
      identity = tracker_identity("repo#2")

      state = %State{
        retry_attempts: %{
          "issue-2" => %{
            attempt: 1,
            timer_ref: nil,
            tracker_identity: identity,
            issue_state: "rework"
          }
        }
      }

      next =
        RetryEngine.schedule_issue_retry(state, "issue-2", 1, %{
          identifier: "repo#2",
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-2"]
      assert retry.tracker_identity == identity
      assert retry.issue_state == "rework"
      Process.cancel_timer(retry.timer_ref)
    end

    test "clears the prior identity when a reschedule explicitly supplies nil" do
      identity = tracker_identity("repo#3")

      state = %State{
        retry_attempts: %{
          "issue-3" => %{attempt: 1, timer_ref: nil, tracker_identity: identity}
        }
      }

      next =
        RetryEngine.schedule_issue_retry(state, "issue-3", 1, %{
          identifier: "repo#3",
          tracker_identity: nil,
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-3"]
      assert retry.tracker_identity == nil
      Process.cancel_timer(retry.timer_ref)
    end
  end
end
