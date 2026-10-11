defmodule Aiur.Orchestrator.Status.PauseResumeCapacityTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  test "pause then resume round trip updates status around worker control messages" do
    # Null the Linear token so the orchestrator's startup poll fails *instantly*
    # with {:error, :missing_linear_api_token} — no real api.linear.app call to
    # block the GenServer (which timed out the 1s `status` call under load), and no
    # successful fetch (which would reconcile the injected running agent away and
    # kill its worker pid, here `self()`). The poll erroring is the pre-fix
    # behavior; this just makes it fast and network-free.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    orchestrator_name = Module.concat(__MODULE__, :PauseResumeRoundTripOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-round-trip" => running_entry("issue-round-trip", "repo#47", :working, parent)
          }
      }
    end)

    assert {:ok, request_id} = Orchestrator.pause_agent(orchestrator_name, "repo#47")
    assert_receive {:pause_agent, ^request_id, 1}, 500

    # Admission only proves routing. The authoritative state remains working
    # until evidence identifies this exact request and worker generation.
    assert [%{identifier: "repo#47", state: :running}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :running}], &1))

    send(pid, {:worker_control_state, "issue-round-trip", :paused, %{request_id: request_id, generation: 1}})

    assert [%{identifier: "repo#47", state: :paused}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :paused}], &1))

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "repo#47")
    assert_receive {:resume_agent, resume_request_id, 1} when is_integer(resume_request_id), 500

    assert [%{identifier: "repo#47", state: :paused}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :paused}], &1))

    send(pid, {:worker_control_state, "issue-round-trip", :working, %{request_id: resume_request_id, generation: 1}})

    assert [%{identifier: "repo#47", state: :running}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :running}], &1))
  end

  test "resuming a paused agent is blocked when active capacity is full" do
    orchestrator_name = Module.concat(__MODULE__, :ResumeCapacityBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused)
          }
      }
    end)

    assert {:error, :max_concurrent_agents_reached} =
             Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED")

    refute_receive {:resume_agent, _request_id}, 100
  end

  test "resuming a paused agent sends resume control and consumes active capacity" do
    orchestrator_name = Module.concat(__MODULE__, :ResumePausedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working, parent),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED")
    assert_receive {:resume_agent, request_id, 1} when is_integer(request_id), 500
    assert %{active: 1, paused: 1, max: 2} = Orchestrator.max_concurrent_agents(orchestrator_name)

    send(pid, {:worker_control_state, "issue-paused", :working, %{request_id: request_id, generation: 1}})
    assert %{active: 2, paused: 0, max: 2} = Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "pause freezes started_at clock — paused_at is captured, started_at unchanged" do
    orchestrator_name = Module.concat(__MODULE__, :PauseClockFreezeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    started_at = DateTime.add(DateTime.utc_now(), -60, :second)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-clock" => %{
              pid: self(),
              ref: make_ref(),
              identifier: "MT-CLOCK",
              issue: %Issue{id: "issue-clock", identifier: "MT-CLOCK", state: "In Progress"},
              control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
              session_id: "thread-MT-CLOCK",
              started_at: started_at
            }
          }
      }
    end)

    send(pid, {:worker_control_state, "issue-clock", :paused, %{kind: :agent_pause_request}})
    Process.sleep(20)

    paused_entry = :sys.get_state(pid).running["issue-clock"]
    assert %DateTime{} = paused_entry[:paused_at]
    assert paused_entry[:started_at] == started_at
  end

  test "resume shifts started_at forward by the paused interval so the age column excludes the pause" do
    orchestrator_name = Module.concat(__MODULE__, :PauseClockShiftOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    started_at = DateTime.add(DateTime.utc_now(), -60, :second)
    paused_at = DateTime.add(DateTime.utc_now(), -5, :second)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-shift" => %{
              pid: self(),
              ref: make_ref(),
              identifier: "MT-SHIFT",
              issue: %Issue{id: "issue-shift", identifier: "MT-SHIFT", state: "In Progress"},
              control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
              session_id: "thread-MT-SHIFT",
              started_at: started_at,
              paused_at: paused_at
            }
          }
      }
    end)

    send(pid, {:worker_control_state, "issue-shift", :working})
    Process.sleep(20)

    resumed_entry = :sys.get_state(pid).running["issue-shift"]
    refute Map.get(resumed_entry, :paused_at)
    # started_at should be shifted forward by ~5s (the pause duration).
    shift_seconds = DateTime.diff(resumed_entry.started_at, started_at, :second)

    assert shift_seconds in 4..6,
           "expected started_at shifted by ~5s, got #{shift_seconds}s"
  end

  test "resuming a paused agent into its reserved slot succeeds when no other active agents" do
    orchestrator_name = Module.concat(__MODULE__, :ResumePausedOnlySlotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # max=1, no active, 1 paused: the paused agent already owns the slot,
    # so resume should succeed even though `available_slots` is 0.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED")
    assert_receive {:resume_agent, request_id, 1} when is_integer(request_id), 500
    assert %{active: 0, paused: 1, max: 1} = Orchestrator.max_concurrent_agents(orchestrator_name)

    send(pid, {:worker_control_state, "issue-paused", :working, %{request_id: request_id, generation: 1}})
    assert %{active: 1, paused: 0, max: 1} = Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "resuming a paused ssh agent is blocked when its worker host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    orchestrator_name = Module.concat(__MODULE__, :ResumePausedWorkerHostBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 3,
          running: %{
            "issue-active-a" => running_entry("issue-active-a", "MT-ACTIVE-A", :working, parent, "worker-a"),
            "issue-active-b" => running_entry("issue-active-b", "MT-ACTIVE-B", :working, parent, "worker-b"),
            "issue-paused-a" => running_entry("issue-paused-a", "MT-PAUSED-A", :paused, parent, "worker-a")
          }
      }
    end)

    assert {:error, :max_concurrent_agents_reached} =
             Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED-A")

    refute_receive {:resume_agent, _request_id}, 100
    assert %{active: 2, paused: 1, max: 3} = Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "running execution facts stay pinned while undispatched routing follows config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: %{3 => "codex:gpt-5.6-terra:high"}
    )

    running_issue = %Issue{
      id: "issue-pinned-execution",
      identifier: "MT-PINNED",
      state: "In Progress",
      labels: ["complexity:3"]
    }

    idle_issue = %Issue{
      id: "issue-undispatched-execution",
      identifier: "MT-UNDISPATCHED",
      state: "Todo",
      labels: ["complexity:3"]
    }

    orchestrator_name = Module.concat(__MODULE__, :PinnedExecutionOrchestrator)
    # This test injects `last_polled_issues` directly; an automatic poll would
    # replace it with tracker truth and drop the undispatched fixture.
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            running_issue.id =>
              running_entry(
                running_issue.id,
                running_issue.identifier,
                :working
              )
              |> Map.put(:issue, running_issue)
          },
          last_polled_issues: %{idle_issue.id => idle_issue}
      }
    end)

    assert %{running: [warming], idle: [undispatched]} =
             Orchestrator.snapshot(orchestrator_name, 5_000)

    assert warming.backend == nil
    assert warming.requested_model == nil
    assert warming.effort == nil
    assert undispatched.backend == "codex"
    assert undispatched.requested_model == "gpt-5.6-terra"
    assert undispatched.effort == "high"

    send(
      pid,
      {:session_execution_info, running_issue.id, %{backend: "codex", requested_model: "gpt-5.6-terra", effort: "high"}}
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: %{3 => "claude:sonnet"}
    )

    assert %{running: [running], idle: [rerouted]} =
             Orchestrator.snapshot(orchestrator_name, 5_000)

    assert running.backend == "codex"
    assert running.agent_family == "codex"
    assert running.requested_model == "gpt-5.6-terra"
    assert running.effort == "high"
    assert rerouted.backend == "claude"
    assert rerouted.requested_model == "sonnet"
    assert rerouted.effort == nil

    # The route asked for a family; only the running agent can say which
    # concrete version answered, and it arrives after the execution facts —
    # so it has to merge in rather than replace what was already reported.
    send(pid, {:session_resolved_model, running_issue.id, "gpt-5.6-terra-2026"})

    assert %{running: [observed]} = Orchestrator.snapshot(orchestrator_name, 5_000)

    assert observed.resolved_model == "gpt-5.6-terra-2026"
    assert observed.backend == "codex"
    assert observed.requested_model == "gpt-5.6-terra"
  end
end
