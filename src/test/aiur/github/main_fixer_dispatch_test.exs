defmodule Aiur.GitHub.MainFixerDispatchTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.Hints
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, Slots, State, TrackerTasks}
  @signature String.duplicate("b", 64)
  @sha String.duplicate("a", 40)

  setup do
    enable_fixer_policy()
    DispatchAuthorization.clear_cache()
    on_exit(fn -> DispatchAuthorization.clear_cache() end)
    :ok
  end

  test "only configured App-authored fixers gain daemon label authorization" do
    opts = [
      allowed_users: ["operator"],
      token: "test",
      bot_account: "agent",
      daemon_account: "daemon[bot]",
      app_account: "daemon[bot]",
      token_source: :github_app,
      request_fun: fn _ ->
        {:ok, %{status: 200, body: [%{"id" => 1, "event" => "labeled", "actor" => %{"login" => "daemon[bot]"}, "label" => %{"name" => "agent:todo"}, "created_at" => "2026-01-01T00:00:00Z"}]}}
      end
    ]

    fixer = issue("1")
    assert DispatchAuthorization.authorize(fixer, "owner", "repo", "agent", opts).dispatch_authorized?
    assert DispatchAuthorization.authorize(%{fixer | labels: ["MAIN-FIX"]}, "owner", "repo", "agent", opts).dispatch_authorized?

    for changed <- [%{fixer | creator_login: "agent"}, %{fixer | labels: []}, %{fixer | description: "copied malformed marker"}] do
      refute DispatchAuthorization.authorize(changed, "owner", "repo", "agent", opts).dispatch_authorized?
    end

    refute DispatchAuthorization.authorize(fixer, "owner", "repo", "agent", Keyword.put(opts, :token_source, :env)).dispatch_authorized?
    refute DispatchAuthorization.authorize(fixer, "owner", "repo", "agent", Keyword.put(opts, :bot_account, "DAEMON[bot]")).dispatch_authorized?
    refute DispatchAuthorization.authorize(fixer, "owner", "repo", "agent", Keyword.put(opts, :main_watch, %{on_red: "alert", fixer_label: "main-fix"})).dispatch_authorized?
  end

  test "fixer beats downstream rank but cannot exceed a full fleet" do
    :ets.new(Hints.table_name(), [:named_table, :set])
    :ets.insert(Hints.table_name(), {"normal", {-100, 0}, false})
    fixer = issue("fixer")
    normal = %{issue("normal") | labels: [], priority: 1}
    assert DispatchPolicy.sort_issues_for_dispatch([normal, fixer]) == [fixer, normal]
    state = %State{max_concurrent_agents: 1, running: %{"normal" => %{issue: normal, control: %{status: :working}}}}
    assert Slots.available_slots(state) == 0
    refute Slots.dispatch_slots_available?(fixer, state)
    assert DispatchPolicy.dispatch_decision(fixer, state) == {:skip, :state_capacity}
    assert DispatchPolicy.dispatch_decision(fixer, %{state | running: %{}}) == :dispatch
    refute Slots.dispatch_slots_available?(fixer, %{state | running: %{}, globally_paused: true})
  end

  test "CI-wait releases ordinary capacity and explicit state caps remain authoritative" do
    normal = %{issue("normal") | labels: []}

    state = %State{
      max_concurrent_agents: 2,
      running: %{
        "normal" => %{issue: normal, control: %{status: :working}},
        "old" => %{issue: issue("old"), control: %{status: :paused}, paused_reason: :ci_wait}
      }
    }

    assert DispatchPolicy.dispatch_decision(issue("new"), state) == :dispatch
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents_by_state: %{todo: 1})
    enable_fixer_policy()
    assert DispatchPolicy.dispatch_decision(issue("new"), state) == {:skip, :state_capacity}
  end

  # Compatibility guard: host admission already applies before candidate selection.
  test "fixer priority does not bypass the host admission gate" do
    assert Slots.dispatch_slots_available?(issue("fixer"), %State{max_concurrent_agents: 1})

    probes = %{
      load: 100.0,
      load_threshold: 0.1,
      cpu_snapshot: %{total: 1_200, idle: 710, nice: 100, runnable: 20},
      runnable: :unavailable,
      run_queue_threshold: nil,
      target: nil,
      schedulers: 1,
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      build_status: %{enabled?: false},
      provider_backends: [],
      github_quota: :available
    }

    state =
      Dispatcher.maybe_choose_under_load(
        %State{max_concurrent_agents: 1, load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: %{total: 1_000, idle: 700, nice: 100, runnable: 20}}},
        [issue("fixer")],
        fn _, _ -> flunk("host load gate was bypassed") end,
        admission_probes_fun: fn -> probes end,
        telemetry_fun: fn _, _ -> :ok end,
        emit_fun: fn _, _ -> :ok end
      )

    assert state.capacity_hold.signal == :load
  end

  test "the polling batch gives the next free slot to the fixer first" do
    parent = self()
    fixer = issue("fixer-launch")
    normal = %{issue("normal-launch") | labels: []}
    state = %State{snapshot_key: self(), max_concurrent_agents: 1, running: %{normal.id => %{issue: normal, control: %{status: :working}}}}

    probes = %{
      load: 0.0,
      load_threshold: nil,
      cpu_snapshot: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      target: nil,
      schedulers: 1,
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      build_status: %{enabled?: false},
      provider_backends: [],
      github_quota: :available
    }

    opts = [
      admission_probes_fun: fn -> probes end,
      issue_fetcher: fn ids -> {:ok, Enum.filter([normal, fixer], &(&1.id in ids))} end,
      blocked_by_hydrator: fn issue -> {:ok, issue} end,
      runner: fn dispatched, _, _ ->
        send(parent, {:started, dispatched.id})
        :ok
      end
    ]

    full = Dispatcher.dispatch_or_hold(state, [normal, fixer], fn -> :ready end, opts)
    refute TrackerTasks.running?(full, {:dispatch, fixer.id})
    refute_receive {:started, _}, 100
    assert Slots.used_slots(full) == 1

    pending = Dispatcher.dispatch_or_hold(%{full | running: %{}}, [normal, fixer], fn -> :ready end, opts)

    assert TrackerTasks.running?(pending, {:dispatch, fixer.id})
    receive_barrier({ref, result})
    assert {:handled, dispatched} = TrackerTasks.result(pending, ref, result)
    receive_barrier({:started, "fixer-launch"})
    assert Map.has_key?(dispatched.running, fixer.id)
    refute Map.has_key?(dispatched.running, normal.id)
    assert Slots.used_slots(dispatched) == 1
  end

  test "fixer honors a pressure-reduced effective cap" do
    normal = %{issue("normal-pressure") | labels: []}
    state = %State{max_concurrent_agents: 3, effective_concurrent_agents: 1, running: %{normal.id => %{issue: normal, control: %{status: :working}}}}
    assert DispatchPolicy.dispatch_decision(issue("pressure-fixer"), state) == {:skip, :fleet_capacity}
  end

  defp enable_fixer_policy do
    content = File.read!(Workflow.workflow_file_path())
    write_workflow_file_atomic!(Workflow.workflow_file_path(), content <> "\nmerge_policy:\n  main_watch:\n    on_red: dispatch_fixer\n")
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: "repo##{id}",
      title: "fix main",
      state: "todo",
      state_labels: ["agent:todo"],
      creator_login: "daemon[bot]",
      labels: ["main-fix"],
      description: "<!-- aiur:main-watch signature=#{@signature} sha=#{@sha} -->"
    }
  end
end
