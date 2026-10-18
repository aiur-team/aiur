defmodule Aiur.Regression.OrchestratorLifecycleTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorLifecycleSupport

  describe "pause/resume semantics" do
    test "pause.request parks a working entry and stamps paused_at" do
      name = Module.concat(__MODULE__, :PauseRequest)
      pid = start_orchestrator(name)
      entry = running_entry("l7", "L7", :working)
      :sys.replace_state(pid, &%{&1 | running: %{"l7" => entry}})

      assert {:ok, request_id} = Orchestrator.pause_agent(name, "L7")
      assert_receive {:pause_agent, ^request_id}, 2000
      entry = :sys.get_state(pid).running["l7"]
      assert get_in(entry, [:control, :status]) == :paused
      assert %DateTime{} = entry.paused_at
    end

    test "a paused entry keeps its slot and holds new dispatch" do
      state = base_state(max_concurrent_agents: 1, running: %{"l8" => running_entry("l8", "L8", :paused)})
      assert Orchestrator.slot_status_for_test(state) == %{active: 0, paused: 1}
      refute Orchestrator.should_dispatch_issue_for_test(todo_issue("fresh-l8"), state)
    end

    test "resume of a paused entry bypasses available_slots" do
      name = Module.concat(__MODULE__, :ResumeBypass)
      pid = start_orchestrator(name)
      entry = running_entry("l9", "L9", :paused)
      :sys.replace_state(pid, &%{&1 | session_max_concurrent_agents: 1, running: %{"l9" => entry}})

      assert {:ok, :resumed} = Orchestrator.resume_agent(name, "L9")
      assert_receive {:resume_agent, request_id} when is_integer(request_id), 2000
    end

    test "resume is refused when active count already fills the cap" do
      name = Module.concat(__MODULE__, :ResumeBlocked)
      pid = start_orchestrator(name)
      running = %{"active" => running_entry("active", "L10A", :working), "paused" => running_entry("paused", "L10P", :paused)}
      :sys.replace_state(pid, &%{&1 | session_max_concurrent_agents: 1, running: running})

      assert {:error, :max_concurrent_agents_reached} = Orchestrator.resume_agent(name, "L10P")
      refute_receive {:resume_agent, _}, 100
    end

    test "resume with no running entry clears tracker pause and starts a queued idle issue" do
      name = Module.concat(__MODULE__, :ResumeQueued)
      pid = start_orchestrator(name)

      issue =
        "L11"
        |> todo_issue()
        |> Map.put(:paused, true)
        |> Map.put(:labels, ["agent:todo", "agent:paused"])

      # The tracker still carries `agent:paused`, so the authoritative re-read
      # agrees with the cache and the resume has a real override to clear.
      memory_tracker!([issue])
      :sys.replace_state(pid, &%{&1 | last_polled_issues: %{issue.id => issue}, running: %{}, claimed: MapSet.new()})

      assert {:ok, :started} = Orchestrator.resume_agent(name, issue.identifier)
      assert_receive {:memory_tracker_remove_label, "L11", "agent:paused"}, 1000
      assert MapSet.member?(:sys.get_state(pid).claimed, issue.id)
      refute :sys.get_state(pid).last_polled_issues[issue.id].paused
    end

    test "resume refreshes stale cached tracker state before deciding dispatchability" do
      name = Module.concat(__MODULE__, :ResumeStaleCachedState)
      pid = start_orchestrator(name)
      tracker_issue = todo_issue("L11-STALE")
      cached_issue = %{tracker_issue | state: "ci-wait"}
      memory_tracker!([tracker_issue])

      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_polled_issues: %{cached_issue.id => cached_issue},
            candidate_snapshot_fresh?: false,
            running: %{},
            claimed: MapSet.new()
        }
      end)

      assert {:ok, :started} = Orchestrator.resume_agent(name, tracker_issue.identifier)
      state = :sys.get_state(pid)
      assert state.last_polled_issues[tracker_issue.id].state == "todo"
      assert MapSet.member?(state.claimed, tracker_issue.id)
    end

    test "resume names a stale-cache rejection with the tracker state" do
      name = Module.concat(__MODULE__, :ResumeStaleRejection)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-REJECT")
      tracker_issue = %{cached_issue | state: "ci-wait"}
      memory_tracker!([tracker_issue])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:stale_tracker_state, {:tracker_state_not_resumable, "ci-wait"}, %{cached_state: "todo", tracker_state: "ci-wait"}}} =
               Orchestrator.resume_agent(name, cached_issue.identifier)

      assert :sys.get_state(pid).last_polled_issues[cached_issue.id].state == "ci-wait"
    end

    test "resume names stale blocker data even when the state label is unchanged" do
      name = Module.concat(__MODULE__, :ResumeStaleBlockers)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-BLOCKED")
      tracker_issue = %{cached_issue | blocked_by: [%{state: "todo"}]}
      memory_tracker!([tracker_issue])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:stale_tracker_state, :waiting_for_dependencies, %{cached_state: "todo", tracker_state: "todo", changed_fields: [:blockers]}}} =
               Orchestrator.resume_agent(name, cached_issue.identifier)
    end

    test "resume revalidates tracker state after clearing the pause override" do
      name = Module.concat(__MODULE__, :ResumeRelabelRace)
      pid = start_orchestrator(name)

      paused_issue =
        "L11-RACE"
        |> todo_issue()
        |> Map.put(:paused, true)
        |> Map.put(:labels, ["agent:todo", "agent:paused"])

      relabelled_issue = %{paused_issue | state: "merging", paused: false, labels: ["agent:merging"]}
      resume_refresh_tracker!([{:ok, [paused_issue]}, {:ok, [relabelled_issue]}])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{paused_issue.id => paused_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:stale_tracker_state, {:tracker_state_not_resumable, "merging"}, %{cached_state: "todo", tracker_state: "merging", changed_fields: [:state]}}} =
               Orchestrator.resume_agent(name, paused_issue.identifier)

      assert_receive {:resume_refresh_remove_label, "L11-RACE", "agent:paused"}, 1000
      refute MapSet.member?(:sys.get_state(pid).claimed, paused_issue.id)
    end

    test "resume reports an authoritative missing ticket" do
      name = Module.concat(__MODULE__, :ResumeMissingTrackerIssue)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-MISSING")
      resume_refresh_tracker!([{:ok, []}])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, :tracker_issue_not_found} = Orchestrator.resume_agent(name, cached_issue.identifier)
      refute Map.has_key?(:sys.get_state(pid).last_polled_issues, cached_issue.id)
    end

    test "resume reports tracker refresh failures without mutating the cache" do
      name = Module.concat(__MODULE__, :ResumeTrackerFailure)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-TRACKER-DOWN")
      resume_refresh_tracker!([{:error, :timeout}])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:tracker_refresh_failed, :timeout}} =
               Orchestrator.resume_agent(name, cached_issue.identifier)

      assert :sys.get_state(pid).last_polled_issues[cached_issue.id] == cached_issue
    end
  end
end
