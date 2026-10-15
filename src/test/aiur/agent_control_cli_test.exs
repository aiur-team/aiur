Code.require_file("orchestrator/control_cli/fixture.exs", __DIR__)

defmodule Aiur.AgentControlCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, AlertLedger, Asks, BuildGate, Config, DecisionStore, DispatchBudgetStore, Issue, RepoBase}
  alias Aiur.Events.SubscriptionStore
  alias Aiur.ExecutorWakeInbox
  alias Aiur.GitHub.CiReadiness
  alias Aiur.GitHub.Quota
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, Lifecycle, State}

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  test "fixture restoration fences queued ticks and poll cycles between cases (#3007)", %{orchestrator: pid} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    original_state = %{orchestrator_state!(pid) | poll_frozen: false}
    :sys.suspend(pid)

    try do
      state = :sys.replace_state(pid, &Lifecycle.schedule_tick(&1, 60_000))
      timer = state.tick_timer_ref
      send(pid, {:tick, state.tick_token})
      send(pid, :run_poll_cycle)

      restore_orchestrator_state(pid, original_state)
      assert Process.read_timer(timer) == false
      :sys.resume(pid)

      # Suspension widens the window across restoration; this system call
      # is a mailbox barrier after both queued messages, not a timing guess.
      restored = orchestrator_state!(pid)
      assert restored.poll_cycles_completed == original_state.poll_cycles_completed
      assert restored.poll_check_in_progress == false
      assert restored.next_poll_due_at_ms == nil
      assert restored.running == original_state.running
    after
      :sys.resume(pid)
    end
  end

  test "fixture state timeout captures the blocked function and mailbox (#3007)", %{orchestrator: pid} do
    parent = self()
    barrier = make_ref()

    blocker =
      Task.async(fn ->
        :sys.replace_state(pid, fn state ->
          send(parent, {:fixture_blocked, barrier})

          receive do
            ^barrier -> state
          end
        end)
      end)

    receive_barrier({:fixture_blocked, ^barrier})
    send(pid, {:fixture_mailbox_evidence, barrier})

    try do
      error = assert_raise ExUnit.AssertionError, fn -> orchestrator_state!(pid, 1) end
      assert error.message =~ "current_function: {Aiur.AgentControlCLITest,"
      assert error.message =~ "fixture state timeout captures the blocked function and mailbox"
      assert error.message =~ "current_stacktrace:"
      assert error.message =~ "fixture_mailbox_evidence"
      assert error.message =~ "message_queue_len:"
    after
      send(pid, barrier)
      Task.await(blocker)
    end
  end

  test "status prints empty and populated tables", %{orchestrator: pid} do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})
    empty_output = capture_io(fn -> AgentControlCLI.status() end)

    assert empty_output =~ "WAKES CURSOR 0 PENDING 0\nDECISIONS "
    assert empty_output =~ "ISSUE STATE  TITLE"
    assert empty_output =~ "(no active agents)"
    assert empty_output =~ "__AIUR_CONTROL_EXIT__:0"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working),
            "88" => running_entry("88", "", :working),
            "issue-alpha" => running_entry("issue-alpha", "worker-alpha", :working)
          }
      }
    end)

    populated_output = capture_io(fn -> AgentControlCLI.status() end)

    assert populated_output =~ "ISSUE STATE   TITLE"
    assert populated_output =~ "#44    running Issue repo#44"
    assert populated_output =~ "#88    running Issue "
    assert populated_output =~ "worker-alpha running Issue worker-alpha"
    assert populated_output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "status reports wake depth as unavailable when the inbox is down" do
    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "WAKES unavailable (cursor and pending count could not be read)"
    refute output =~ "WAKES CURSOR 0 PENDING 0"
  end

  test "status renders dispatch poll age and honest missing observations" do
    for {polling, expected} <- [
          {%{last_dispatch_poll_age_ms: 481_000, effective_interval_ms: 240_000}, "481s ago (stale)"},
          {%{last_dispatch_poll_age_ms: 20_000, effective_interval_ms: 240_000}, "20s ago (fresh)"},
          {%{last_dispatch_poll_age_ms: nil}, "never polled"},
          {%{}, "unavailable"}
        ] do
      snapshot = %{statuses: [], polling: polling}
      output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, snapshot, %{status: :current, reason: nil, age_seconds: 0}}) end)
      assert output =~ "POLL last dispatch: #{expected}"
    end
  end

  test "status surfaces an active idle polling backoff" do
    snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      polling: %{
        checking?: false,
        next_poll_in_ms: 590_000,
        poll_interval_ms: 120_000,
        effective_interval_ms: 600_000,
        idle_backoff: %{active?: true, factor: 5.0}
      }
    }

    freshness = %{status: :current, reason: nil, age_seconds: 0}

    output =
      capture_io(fn ->
        AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness})
      end)

    assert output =~ "POLL idle backoff active: interval=600s base=120s factor=5.0x next=590s"
  end

  # #2309 acceptance: `aiur status` shows the live interval per class, so an
  # operator can see planning is on-demand (0) while dispatch is at 2 minutes
  # without reading config.
  test "status prints the live poll interval per class" do
    snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      polling: %{
        checking?: false,
        next_poll_in_ms: 590_000,
        poll_interval_ms: 120_000,
        effective_interval_ms: 600_000,
        idle_backoff: %{active?: true, factor: 5.0},
        class_intervals: %{dispatch: 120_000, ci: 60_000, review: 300_000, planning: 0, firehose: 0}
      }
    }

    freshness = %{status: :current, reason: nil, age_seconds: 0}

    output =
      capture_io(fn ->
        AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness})
      end)

    assert output =~ "POLL class intervals: ci=60s dispatch=120s firehose=0s planning=0s review=300s"
  end

  defp unconstrained_capacity(overrides \\ %{}) do
    Map.merge(
      %{
        occupied: 0,
        max: 2,
        effective: 2,
        configured: 2,
        available: 2,
        queued_demand?: false,
        session_override?: false,
        active: 0,
        reserved_paused: 0,
        capacity_hold: nil
      },
      overrides
    )
  end

  # The core #2138 status defect: `binding: ticket supply` was reported while
  # claimable tickets existed, because the daemon had not polled recently enough
  # to see them. While idle backoff is active (or the candidate snapshot is not
  # fresh), the line must say the fleet has not polled, never blame ticket
  # supply.
  test "status never blames ticket supply while the fleet is idle-backed off" do
    snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      capacity: unconstrained_capacity(),
      polling: %{
        checking?: false,
        next_poll_in_ms: 590_000,
        poll_interval_ms: 120_000,
        effective_interval_ms: 600_000,
        idle_backoff: %{active?: true, factor: 5.0},
        tracker_snapshot_fresh?: true
      }
    }

    freshness = %{status: :current, reason: nil, age_seconds: 0}

    output =
      capture_io(fn ->
        AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness})
      end)

    # The backoff is designed, so the line names the cause and the knob that
    # sized it rather than reading as a fault — and never says "has not polled
    # yet", because a backoff only exists after a completed poll (#2640).
    assert output =~
             "AGENTS 0/2 (binding: idle backoff active (no dispatchable demand at last poll; polling.idle_widen_factor=5.0, next poll in 590s; ceiling: config max_concurrent_agents))"

    refute output =~ "binding: ticket supply"
    refute output =~ "has not polled yet"
  end

  test "status never blames ticket supply when the last candidate fetch failed" do
    snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      capacity: unconstrained_capacity(),
      polling: %{
        checking?: false,
        next_poll_in_ms: 1_000,
        poll_interval_ms: 120_000,
        effective_interval_ms: 120_000,
        idle_backoff: %{active?: false, factor: 5.0},
        tracker_snapshot_fresh?: false
      }
    }

    freshness = %{status: :current, reason: nil, age_seconds: 0}

    output =
      capture_io(fn ->
        AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness})
      end)

    assert output =~ "AGENTS 0/2 (binding: has not polled yet (ceiling: config max_concurrent_agents))"
    refute output =~ "binding: ticket supply"
  end

  # Criterion 5 of #2138: `set max-agents` is a session cap and does not
  # survive a restart, so an unconstrained fleet's AGENTS line must show where
  # the effective ceiling came from — an operator whose live cap was silently
  # dropped reads `config` rather than their last command.
  test "status shows the effective ceiling source when the fleet is unconstrained" do
    freshness = %{status: :current, reason: nil, age_seconds: 0}

    polling = %{
      checking?: false,
      next_poll_in_ms: 1_000,
      poll_interval_ms: 120_000,
      effective_interval_ms: 120_000,
      idle_backoff: %{active?: false, factor: 5.0},
      tracker_snapshot_fresh?: true
    }

    session_snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      capacity: unconstrained_capacity(%{max: 2, configured: 16, session_override?: true}),
      polling: polling
    }

    session_output =
      capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, session_snapshot, freshness}) end)

    assert session_output =~ "AGENTS 0/2 (binding: ticket supply; ceiling: session max_concurrent_agents)"

    config_snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      capacity: unconstrained_capacity(%{max: 16, configured: 16, session_override?: false}),
      polling: polling
    }

    config_output =
      capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, config_snapshot, freshness}) end)

    assert config_output =~ "AGENTS 0/16 (binding: ticket supply; ceiling: AIMD envelope 2)"
    refute config_output =~ "ceiling: session"
  end

  test "status surfaces whether the Executor listener is currently listening", %{orchestrator: _pid} do
    previous = Application.get_env(:aiur, :executor_listener_alive_fun)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :executor_listener_alive_fun)
      else
        Application.put_env(:aiur, :executor_listener_alive_fun, previous)
      end
    end)

    defaults = Aiur.ExecutorBindings.patterns()
    Application.put_env(:aiur, :executor_listener_alive_fun, fn -> defaults end)
    present = capture_io(fn -> AgentControlCLI.status() end)
    assert present =~ "LISTENER present (#{length(defaults)} bindings: executor.#"

    Application.put_env(:aiur, :executor_listener_alive_fun, fn -> tl(defaults) end)
    degraded = capture_io(fn -> AgentControlCLI.status() end)
    assert degraded =~ "LISTENER degraded (#{length(defaults) - 1}/#{length(defaults)} bindings; MISSING: executor.#)"

    Application.put_env(:aiur, :executor_listener_alive_fun, fn -> [] end)
    # Recording is armed on every run now, so absence is no longer a mode the
    # operator could have chosen — it is a fault, and the line has to say so.
    absent = capture_io(fn -> AgentControlCLI.status() end)
    assert absent =~ "LISTENER absent (FAULT:"
    assert absent =~ "are not being recorded"
  end

  test "status distinguishes paused reasons and names dependency blockers", %{orchestrator: pid} do
    dependency = %Issue{
      id: "issue-99",
      identifier: "repo#99",
      state: "todo",
      title: "Dependency",
      blocked_by: [%{id: "issue-12", identifier: "repo#12", state: "in-progress"}]
    }

    paused =
      running_entry("issue-44", "repo#44", :paused)
      |> Map.put(:paused_reason, :agent_pause_request)
      |> Map.put(:issue, %Issue{id: "issue-44", identifier: "repo#44", state: "in-progress", title: "Needs input"})

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => paused}, last_polled_issues: %{"issue-99" => dependency}}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#44    paused"
    assert output =~ "waiting=paused"
    assert output =~ "pause_reason=agent_pause_request"
    assert output =~ "#99    idle"
    assert output =~ "waiting=waiting_for_dependency"
    assert output =~ "blocked_by=repo#12"
  end

  test "status names a blocking Command dispatch decline", %{orchestrator: pid} do
    issue = %Issue{id: "issue-1965", identifier: "repo#1965", state: "todo", title: "Needs decision"}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{issue.id => issue},
          dispatch_declines: %{issue.id => :blocked_on_decision}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#1965  idle"
    assert output =~ "dispatch_decline=blocked_on_decision"
  end

  test "status renders a stale revalidation dispatch decline without failing", %{orchestrator: pid} do
    issue = %Issue{id: "issue-2832", identifier: "repo#2832", state: "todo", title: "Stale dispatch"}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{issue.id => issue},
          dispatch_declines: %{issue.id => {:stale_after_revalidation, :unauthorized}}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#2832  idle"
    assert output =~ "dispatch_decline={:stale_after_revalidation, :unauthorized}"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute output =~ "status query failed"
  end

  test "status makes degraded supervision explicit" do
    Application.put_env(:aiur, :supervision_health_status_fun, fn ->
      {:ok, %{expected: 2, healthy: 1, missing: [%{id: Aiur.Events.IdGenerator, reason: :killed}]}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :supervision_health_status_fun) end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "SUPERVISION 1/2 — Aiur.Events.IdGenerator DOWN (last termination: :killed)"
    refute output =~ "SUPERVISION 2/2 healthy"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "status prints healthy and unavailable supervision states" do
    Application.put_env(:aiur, :supervision_health_status_fun, fn -> {:ok, %{expected: 2, healthy: 2, missing: []}} end)

    healthy_output = capture_io(fn -> AgentControlCLI.status() end)
    assert healthy_output =~ "SUPERVISION 2/2 healthy"
    assert healthy_output =~ "__AIUR_CONTROL_EXIT__:0"

    Application.put_env(:aiur, :supervision_health_status_fun, fn -> {:error, :unavailable} end)

    unavailable_output = capture_io(fn -> AgentControlCLI.status() end)
    assert unavailable_output =~ "SUPERVISION unavailable"
    assert unavailable_output =~ "__AIUR_CONTROL_EXIT__:1"

    on_exit(fn -> Application.delete_env(:aiur, :supervision_health_status_fun) end)
  end

  test "status names awaiting dispatch and transient retry causes", %{orchestrator: pid} do
    idle = %Issue{id: "issue-17", identifier: "repo#17", state: "todo", title: "Awaiting dispatch"}
    retry = %Issue{id: "issue-18", identifier: "repo#18", state: "todo", title: "Retrying", labels: ["agent:todo", "agent:paused"], paused: true}
    due_at_ms = System.monotonic_time(:millisecond) + 240_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{idle.id => idle, retry.id => retry},
          retry_attempts: %{
            retry.id => %{
              identifier: retry.identifier,
              attempt: 1,
              due_at_ms: due_at_ms,
              error: "tracker 403"
            }
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#17    idle    Awaiting dispatch (awaiting-dispatch)"
    assert output =~ "#18    retrying Retrying (operator; transient: tracker 403, retry ~4m)"
  end

  test "status names an in-progress claim with no live agent as orphaned", %{orchestrator: pid} do
    orphan = %Issue{id: "issue-orphan", identifier: "repo#2076", state: "in-progress", title: "Orphaned claim"}

    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{orphan.id => orphan}, running: %{}}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#2076  idle    Orphaned claim (orphaned claim: no live agent) [waiting=orphaned_claim]"
    refute output =~ "Orphaned claim (awaiting-dispatch)"
  end

  test "status names a post-reconciliation in-progress claim as stale, not awaiting-dispatch", %{orchestrator: pid} do
    stale = %Issue{id: "issue-stale", identifier: "repo#2076b", state: "in-progress", title: "Stale claim"}

    :sys.replace_state(pid, fn state ->
      %{state | startup_claim_reconciliation_complete?: true, last_polled_issues: %{stale.id => stale}, running: %{}}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "Stale claim (stale in-progress claim: no live agent) [waiting=stale_claim]"
    refute output =~ "Stale claim (awaiting-dispatch)"
    refute output =~ "Stale claim (orphaned claim"
  end

  test "status counts released claims awaiting automatic re-claim", %{orchestrator: pid} do
    released = %Issue{id: "issue-released", identifier: "repo#1475", state: "todo", title: "Reclaim me"}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{released.id => released},
          auto_resume: %{
            released.id => %{attempt: 1, cause: :rate_limit, scheduled_at_ms: System.monotonic_time(:millisecond)}
          },
          released_claims: %{released.id => %{cause: :rate_limit, details: %{}, released_at_ms: System.monotonic_time(:millisecond)}}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#1475  idle    Reclaim me (claim released: rate limit; automatic re-claim ~2m)"
    assert output =~ "RELEASED CLAIMS 1 (automatic re-claim pending)"
  end

  test "status retains a released claim after automatic re-claim is unavailable", %{orchestrator: pid} do
    released = %Issue{id: "issue-released-no-retry", identifier: "repo#1476", state: "todo", title: "Needs operator recovery"}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{released.id => released},
          released_claims: %{released.id => %{cause: :tracker_retry_exhausted, details: %{}, released_at_ms: System.monotonic_time(:millisecond)}}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#1476  idle    Needs operator recovery (claim released: tracker retry exhausted)"
    assert output =~ "RELEASED CLAIMS 1 (operator recovery required for some claims)"
  end

  test "status hides a released claim once the ticket reaches a terminal tracker state (#1475)", %{orchestrator: pid} do
    active = %Issue{id: "issue-released-active", identifier: "repo#1477", state: "todo", title: "Still recoverable"}
    closed = %Issue{id: "issue-released-closed", identifier: "repo#1478", state: "Done", title: "Already closed"}
    release = %{cause: :tracker_retry_exhausted, details: %{}, released_at_ms: System.monotonic_time(:millisecond)}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{active.id => active, closed.id => closed},
          released_claims: %{active.id => release, closed.id => release}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#1477  idle    Still recoverable (claim released: tracker retry exhausted)"
    refute output =~ "#1478"

    # The headline must be computed from the rows that are printed, so a claim
    # nobody can act on cannot inflate the count behind the operator's back.
    assert output =~ "RELEASED CLAIMS 1 (operator recovery required for some claims)"
    refute output =~ "RELEASED CLAIMS 2"
  end

  test "status shows a durable lifetime latch after in-memory recovery state is lost", %{orchestrator: pid} do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_dispatches_per_ticket: 40
    )

    issue_id = "issue-latched-status"
    issue = %Issue{id: issue_id, identifier: "repo#1712", state: "error", title: "Terminal latch"}
    maximum = Config.agent_max_dispatches_per_ticket()
    :ok = DispatchBudgetStore.put_lifetime(issue_id, maximum)

    on_exit(fn -> DispatchBudgetStore.reset(issue_id) end)

    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{issue_id => issue}, dispatch_recovery: %State{}.dispatch_recovery}
    end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~
             "#1712  idle    Terminal latch (latched #{maximum}/#{maximum})"
  end

  test "status names a tracker pause as operator-paused", %{orchestrator: pid} do
    paused = %Issue{
      id: "issue-19",
      identifier: "repo#19",
      state: "todo",
      title: "Operator pause",
      labels: ["agent:todo", "agent:paused"],
      paused: true
    }

    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{paused.id => paused}}
    end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~
             "#19    paused  Operator pause (operator)"
  end

  test "status includes the repository readiness line" do
    restore_workflow_file_after_test()
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    parent = self()

    Application.put_env(:aiur, :ci_readiness_check_fun, fn _opts ->
      send(parent, :ci_readiness_checked)
      {:ok, %{ready?: false, base_branch: "main", issues: [:no_pr_workflow]}}
    end)

    CiReadiness.cache_result(%{ready?: false, base_branch: "main", issues: [:no_pr_workflow]})

    on_exit(fn ->
      Application.delete_env(:aiur, :ci_readiness_check_fun)
      CiReadiness.clear_cached_result()
    end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~ "CI readiness: not ready for main"
    refute_receive :ci_readiness_checked, 100
  end

  test "status reports unavailable before the dispatcher has a readiness result" do
    restore_workflow_file_after_test()
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    CiReadiness.clear_cached_result()
    on_exit(&CiReadiness.clear_cached_result/0)

    assert capture_io(fn -> AgentControlCLI.status() end) =~ "CI readiness: unavailable"
  end

  test "status names the config cap and AIMD envelope binding constraints", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working),
            "issue-45" => running_entry("issue-45", "repo#45", :working)
          },
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    config_output = capture_io(fn -> AgentControlCLI.status() end)
    assert config_output =~ "AGENTS 2/2 (binding: config max_concurrent_agents)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 1,
          running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)},
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    envelope_output = capture_io(fn -> AgentControlCLI.status() end)
    assert envelope_output =~ "AGENTS 1/2 (binding: AIMD envelope, effective cap=1)"
  end

  test "status shows provider freshness detail for a provider capacity hold" do
    snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      capacity:
        unconstrained_capacity(%{
          capacity_hold: %{
            signal: :provider,
            measured: ["codex"],
            detail: "backends=codex=stale observed_at=2026-10-06T10:00:00Z next_probe=unknown",
            threshold: :all_usage_limited,
            held_since_ms: System.monotonic_time(:millisecond),
            measured_at: DateTime.utc_now()
          }
        }),
      polling: %{}
    }

    freshness = %{status: :current, reason: nil, age_seconds: 0}

    output =
      capture_io(fn ->
        AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness})
      end)

    assert output =~
             "AGENTS 0/2 (binding: provider, backends=codex=stale observed_at=2026-10-06T10:00:00Z next_probe=unknown sampled=0s ago)"
  end

  test "status reports only the daemon's own admission hold as the binding constraint", %{orchestrator: pid} do
    local_schedulers = System.schedulers_online()
    local_load = local_schedulers * 2.0
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{local_load} 1.0 1.0 1/1 1"} end)

    on_exit(fn ->
      if previous_loadavg,
        do: Application.put_env(:aiur, :loadavg_source_override, previous_loadavg),
        else: Application.delete_env(:aiur, :loadavg_source_override)
    end)

    # The load gate holds only against a measured CPU window (#2089), so the
    # probes carry a `/proc/stat` sample and the sampled state carries the
    # baseline a polling daemon would already hold: 10 idle jiffies out of 200 is
    # 5% reclaimable.
    baseline_cpu = %{total: 1_000, idle: 700, nice: 100, runnable: 20}
    current_cpu = %{total: 1_200, idle: 710, nice: 100, runnable: 20}
    contention = %{idle_percent: 5.0, nice_percent: 0.0, reclaimable_percent: 5.0, runnable: 20}

    probes = %{
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      schedulers: local_schedulers,
      load: local_load,
      load_threshold: 1.5,
      build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
      provider_backends: [],
      github_quota: :available,
      cpu_snapshot: current_cpu,
      cpu_headroom: contention,
      target: nil
    }

    assert {:hold, %{signal: :load, measured: ^local_load, threshold: threshold}} =
             DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, true))

    assert threshold == local_schedulers * 1.5

    sampled =
      :sys.get_state(pid)
      |> Map.merge(%{
        max_concurrent_agents: 10,
        effective_concurrent_agents: 10,
        last_polled_issues: %{"queued" => queued_issue()},
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: baseline_cpu, bootstrap_complete?: true}
      })
      |> Dispatcher.maybe_choose_under_load(
        [queued_issue()],
        fn state, _issues ->
          send(self(), :dispatched)
          state
        end,
        admission_probes_fun: fn -> probes end
      )

    refute_received :dispatched

    assert %{signal: :load, measured: ^local_load, threshold: ^threshold, reclaimable_cpu_percent: 5.0} =
             sampled.capacity_hold

    # A persisted hold without corroboration fields still has to render (an older
    # daemon's state, or a signal that carries none).
    :sys.replace_state(pid, fn _state ->
      %{sampled | capacity_hold: Map.drop(sampled.capacity_hold, [:reclaimable_cpu_percent, :reclaimable_cpu_threshold])}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    # Every admission measurement carries the age of the sample it came from, so
    # a figure minutes older than the `LOAD` line beside it cannot read as
    # current (#2527).
    assert output =~ "AGENTS 0/10 (binding: load, load=#{local_load} threshold=#{threshold} sampled="
    assert output =~ ~r/AGENTS 0\/10 \(binding: load, .* sampled=\d+s ago\)/

    assert output =~
             "LOAD (local fallback diagnostic) #{local_load} threshold=#{threshold} schedulers=#{local_schedulers} " <>
               "(local host sample; over fallback load threshold, PSI governs dispatch when available)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | capacity_hold:
            Map.merge(state.capacity_hold, %{
              reclaimable_cpu_percent: 5.0,
              reclaimable_cpu_threshold: 60.0
            })
      }
    end)

    corroborated_output = capture_io(fn -> AgentControlCLI.status() end)

    assert corroborated_output =~
             "AGENTS 0/10 (binding: load+cpu contention, load=#{local_load} threshold=#{threshold} " <>
               "reclaimable_cpu=5.0% threshold=60.0% sampled="

    # The daemon still holds. A quiet LOCAL sample must not clear the daemon's
    # decision, and the local line must never claim to be the fleet's binding
    # constraint.
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 1.0 1.0 1/1 1"} end)

    persisted_hold_output = capture_io(fn -> AgentControlCLI.status() end)

    assert persisted_hold_output =~
             "AGENTS 0/10 (binding: load+cpu contention, load=#{local_load} threshold=#{threshold} " <>
               "reclaimable_cpu=5.0% threshold=60.0% sampled="

    assert persisted_hold_output =~ "LOAD (local fallback diagnostic) 0.0 threshold=#{threshold} schedulers=#{local_schedulers} (local host sample)"
    refute persisted_hold_output =~ "(binding: load)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | capacity_hold:
            Map.merge(state.capacity_hold, %{
              signal: :run_queue,
              measured: 74,
              threshold: 24.0
            })
      }
    end)

    run_queue_output = capture_io(fn -> AgentControlCLI.status() end)

    assert run_queue_output =~
             "AGENTS 0/10 (binding: run_queue+cpu contention, runnable=74 threshold=24.0 " <>
               "reclaimable_cpu=5.0% threshold=60.0% sampled="

    # A sample the daemon has not refreshed for several poll cycles was taken on
    # a tick that never ran. It is still the last thing the daemon measured, so
    # it keeps its place on the line — but it may no longer read as current.
    :sys.replace_state(pid, fn state ->
      %{state | capacity_hold: Map.put(state.capacity_hold, :measured_at, DateTime.add(DateTime.utc_now(), -600, :second))}
    end)

    stale_output = capture_io(fn -> AgentControlCLI.status() end)

    assert stale_output =~ ~r/AGENTS 0\/10 \(binding: run_queue\+cpu contention, .* sampled=600s ago STALE\)/

    # The inverse, and the actual regression guard: the daemon is NOT holding,
    # but the CLI's own host is over the CLI's own threshold. A locally
    # re-derived gate used to print "binding: load" here — a fleet-level cause
    # the daemon never decided (#1610).
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{local_load} 1.0 1.0 1/1 1"} end)

    :sys.replace_state(pid, fn _state ->
      %{sampled | capacity_hold: nil, last_dispatch_poll_at_ms: System.monotonic_time(:millisecond)}
    end)

    fallback_output = capture_io(fn -> AgentControlCLI.status() end)

    assert fallback_output =~ "AGENTS 0/10 (binding: awaiting dispatch; ceiling: config max_concurrent_agents)"
    refute fallback_output =~ "AGENTS 0/10 (binding: load"

    assert fallback_output =~
             "LOAD (local fallback diagnostic) #{local_load} threshold=#{threshold} schedulers=#{local_schedulers} " <>
               "(local host sample; over fallback load threshold, PSI governs dispatch when available)"
  end

  test "status gives the GitHub quota measurement and its observation time", %{orchestrator: pid} do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 16,
          effective_concurrent_agents: 16,
          capacity_hold: %{
            signal: :github_quota,
            measured: %{resource: "graphql", remaining: 143, limit: 5000, observed_at: observed_at},
            threshold: :ten_percent_remaining,
            held_since_ms: System.monotonic_time(:millisecond),
            alerted?: false
          },
          last_polled_issues: %{"queued" => queued_issue()}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~
             "AGENTS 0/16 (binding: github_quota, resource=graphql remaining=143/5000 measured_at=#{DateTime.to_iso8601(observed_at)})"

    :sys.replace_state(pid, fn state ->
      put_in(state.capacity_hold.measured.observed_at, DateTime.add(observed_at, -121, :second))
    end)

    stale_output = capture_io(fn -> AgentControlCLI.status() end)

    assert stale_output =~
             "AGENTS 0/16 (binding: github_quota stale, last_resource=graphql last_remaining=143/5000 last_measured_at="
  end

  test "status treats blocked tracker rows as ticket supply, not dispatch demand", %{orchestrator: pid} do
    # Deliberately run this at a HIGH local load with the daemon NOT holding
    # (capacity_hold: nil). Ticket supply is the real binding constraint here;
    # a locally re-derived load gate used to overwrite it with "binding: load"
    # (#1610). A pinned 0.0 loadavg would let that defect pass unnoticed, so the
    # sample is pushed well over the local threshold on purpose.
    schedulers = System.schedulers_online()
    saturated_load = schedulers * 2.0
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{saturated_load} 1.0 1.0 1/1 1"} end)

    on_exit(fn ->
      if previous_loadavg,
        do: Application.put_env(:aiur, :loadavg_source_override, previous_loadavg),
        else: Application.delete_env(:aiur, :loadavg_source_override)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          capacity_hold: nil,
          # A recent successful poll found nothing dispatchable (every row is
          # paused or unauthorized), so "ticket supply" is the honest binding
          # here. This requires the fleet NOT to be idle-backed-off: a backed
          # off / failed-fetch fleet is "has not polled yet", never a claim
          # about ticket supply (#2138).
          candidate_snapshot_fresh?: true,
          last_dispatch_poll_at_ms: System.monotonic_time(:millisecond),
          idle_poll_backoff: %{active?: false, factor: 5.0},
          last_polled_issues: %{
            "issue-paused" => Map.put(queued_issue(), :paused, true),
            "issue-unauthorized" => Map.put(queued_issue("issue-unauthorized"), :dispatch_authorized?, false)
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 0/2 (binding: ticket supply; ceiling: config max_concurrent_agents)"
    refute output =~ "AGENTS 0/2 (binding: load"

    # The local reading is still reported — just as a local host sample, not as
    # the fleet's decision.
    assert output =~
             "LOAD (local fallback diagnostic) #{saturated_load} threshold=#{schedulers * 1.5} schedulers=#{schedulers} " <>
               "(local host sample; over fallback load threshold, PSI governs dispatch when available)"
  end

  test "status counts paused reservations as occupied capacity", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          running: %{
            "issue-paused" =>
              running_entry("issue-paused", "repo#paused", :paused)
              |> Map.put(:paused_reason, :operator_pause),
            "issue-paused-two" =>
              running_entry("issue-paused-two", "repo#paused-two", :paused)
              |> Map.put(:paused_reason, :operator_pause)
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 2/2 (binding: paused reservations=2)"
    refute output =~ "binding: ticket supply"
  end

  test "status does not blame paused reservations when the cap is already binding", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 3,
          session_max_concurrent_agents: 1,
          effective_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "repo#active", :working),
            "issue-paused" =>
              running_entry("issue-paused", "repo#paused", :paused)
              |> Map.put(:paused_reason, :operator_pause)
          },
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 2/1 (binding: session max_concurrent_agents)"
    refute output =~ "paused reservations"
  end

  test "status uses a source-neutral session cap label", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 3,
          session_max_concurrent_agents: 1,
          effective_concurrent_agents: 1,
          running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working)
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 1/1 (binding: session max_concurrent_agents)"
    refute output =~ "requested CLI cap"
  end

  test "status prints the resolved CODEOWNERS trust snapshot", %{orchestrator: pid} do
    path = Path.join(File.cwd!(), ".github/CODEOWNERS")

    Application.put_env(:aiur, :agent_control_cli_trust_snapshot_fun, fn ->
      %{trusted: ["its-applekid", "its-everdred"], source: :file, path: path, degradation: %{cause: :repo_owner_unknown, observed_at: nil}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_trust_snapshot_fun) end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "COMMENT TRUST source=file trusted=[@its-applekid, @its-everdred] path=.github/CODEOWNERS degraded=Repository owner is unknown age unknown"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert Process.alive?(pid)
  end

  @tag stale_dispatch_poll: true
  test "status fixture refreshes an inherited stale dispatch poll", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{"issue-queued" => queued_issue()}, max_concurrent_agents: 10}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ ~r/AGENTS 0\/10 \(binding: awaiting dispatch; ceiling: AIMD envelope \d+\)/

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_dispatch_poll_at_ms: System.monotonic_time(:millisecond) - 100_000,
          poll_interval_ms: 1_000,
          effective_poll_interval_ms: 1_000
      }
    end)

    stale_output = capture_io(fn -> AgentControlCLI.status() end)
    assert stale_output =~ ~r/AGENTS 0\/10 \(binding: dispatch poll stale \(\d+s ago\)\)/
    refute stale_output =~ "binding: awaiting dispatch"
  end

  test "status reports active build-gate contention", %{orchestrator: pid} do
    gate_dir = Aiur.TestSupport.tmp_root!("aiur-build-gate-status")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    release_path = Path.join(gate_dir, "holder.release")
    slot_lock = Path.join(lock_dir, "slot-1.lock")
    slot_owner = Path.join(gate_dir, "slot-1.owner")
    queue_path = Path.join(gate_dir, "queue/lease-v2-status")

    metadata =
      "version=2\ntoken=status\npid=2\npgid=1\nphase=test\ncommand=test\n" <>
        "started_at=#{System.os_time(:second) - 90}\n"

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)

    slots = Config.max_concurrent_builds()
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: slots)
    File.mkdir_p!(Path.join(gate_dir, "queue"))
    File.write!(slot_owner, metadata)
    File.write!(queue_path, metadata)

    bash = System.find_executable("bash") || flunk("bash is required for build-gate status tests")

    script = ~S"""
    exec 8<>"$1"
    flock 8
    exec 9<>"$2"
    flock 9
    """

    holder = Aiur.BuildGateTestHolder.start!(bash, script, ["build-gate-holder", slot_lock, queue_path], Path.dirname(slot_lock), release_path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      Aiur.TestCleanup.rm_rf!(gate_dir)
      Aiur.TestCleanup.rm_rf!(lock_dir)
    end)

    assert %{active: 1, queued: 1} = BuildGate.status()

    # Pin the cap this test asserts. The checked-in fixture config sets none, so
    # the orchestrator boots with the host-core default and the `0/10` assertion
    # only ever passed by inheriting an earlier test's state.
    :sys.replace_state(pid, fn state ->
      issue = %Issue{id: "issue-idle", identifier: "repo#idle", state: "In Progress", title: "Idle"}
      %{state | last_polled_issues: %{"issue-idle" => issue}, max_concurrent_agents: 10}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ ~r/AGENTS 0\/10 \(binding: awaiting dispatch; ceiling: AIMD envelope \d+\)/
    assert output =~ "BUILD GATE 1/#{Config.max_concurrent_builds()} active, 1 queued"
    assert output =~ "BUILD GATE HOLDER slot=1 pid=2 command=\"test\" held="
    assert output =~ "BUILD GATE QUEUED pid=2 command=\"test\" waiting="
    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
  end

  test "status distinguishes a slot held without a command from a busy gate", %{orchestrator: pid} do
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-leaked-#{System.unique_integer([:positive])}")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    release_path = Path.join(gate_dir, "holder.release")
    slot_lock = Path.join(lock_dir, "slot-1.lock")
    slot_owner = Path.join(gate_dir, "slot-1.owner")
    queue_path = Path.join(gate_dir, "queue/lease-v2-status")
    timeout_path = Path.join(gate_dir, "slot-1.hold-timeout")

    # `command_pgid=999999999` is dead: the slot is locked but no command is
    # running — the #2349 leaked-holder shape.
    metadata =
      "version=2\ntoken=status\npid=2\npgid=1\nholder_pid=2\ncommand_pgid=999999999\n" <>
        "phase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 90}\n"

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)

    slots = Config.max_concurrent_builds()
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: slots)
    File.mkdir_p!(Path.join(gate_dir, "queue"))
    File.write!(slot_owner, metadata)
    File.write!(queue_path, metadata)
    File.write!(timeout_path, "version=2\ncommand=mix test\nheld_for_seconds=3600\nreason=retained\n")

    bash = System.find_executable("bash") || flunk("bash is required for build-gate status tests")

    script = ~S"""
    exec 8<>"$1"
    flock 8
    exec 9<>"$2"
    flock 9
    """

    holder = Aiur.BuildGateTestHolder.start!(bash, script, ["build-gate-holder", slot_lock, queue_path], Path.dirname(slot_lock), release_path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      Aiur.TestCleanup.rm_rf!(gate_dir)
      Aiur.TestCleanup.rm_rf!(lock_dir)
    end)

    :sys.replace_state(pid, fn state ->
      issue = %Issue{id: "issue-idle", identifier: "repo#idle", state: "In Progress", title: "Idle"}
      %{state | last_polled_issues: %{"issue-idle" => issue}, max_concurrent_agents: 10}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ "BUILD GATE 0/#{Config.max_concurrent_builds()} active, 1 held without a command, 1 queued"
    assert output =~ "BUILD GATE HOLDER slot=1 pid=2 command=\"mix test\" held="
    assert output =~ "(command gone)"
    assert output =~ "BUILD GATE TIMEOUT slot=1 command=\"mix test\" held=1h0m reason=retained"
    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
  end

  test "status reports actionable legacy build-gate degradation" do
    gate_dir = Aiur.TestSupport.tmp_root!("aiur-build-gate-legacy")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    legacy_path = Path.join(gate_dir, "slot-1")

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)

    slots = Config.max_concurrent_builds()
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: slots)
    File.write!(legacy_path, "pid=2\npgid=1\ncommand=test\n")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      Aiur.TestCleanup.rm_rf!(gate_dir)
      Aiur.TestCleanup.rm_rf!(lock_dir)
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ "BUILD GATE DEGRADED 0/#{Config.max_concurrent_builds()} active, 0 queued"
    assert output =~ "reason=legacy_state path=#{legacy_path}"
    assert output =~ "recovery=repair the configured build-gate directory"
  end

  describe "prewarm status surface" do
    # Prewarm-enabled config for the CLI surface tests. No `base_build` and a
    # memory tracker keep RepoBase's own resolve/poll inert (no clone/build can
    # start) while `Config.prewarm_enabled?/0` reads true.
    defp with_prewarm_enabled do
      tmp = Aiur.TestSupport.tmp_root!("cli_prewarm")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      File.write!(cfg, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  poll_seconds: 0\n")
      previous = Application.get_env(:aiur, :workflow_file_path)
      Aiur.Workflow.set_workflow_file_path(cfg)

      on_exit(fn ->
        case previous do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          path -> Aiur.Workflow.set_workflow_file_path(path)
        end
      end)

      :ok
    end

    # Drive the live RepoBase phase so `aiur status` renders the prewarm line
    # exactly as it would against a warming/errored base.
    defp with_repo_base_phase(phase) do
      pid = Process.whereis(RepoBase) || flunk("RepoBase must be running for prewarm status tests")
      original = :sys.get_state(pid)

      :sys.replace_state(pid, fn state -> %{state | phase: phase, base_path: "/tmp/base"} end)

      on_exit(fn -> restore_repo_base(pid, original) end)

      :ok
    end

    defp restore_repo_base(pid, original) do
      if Process.alive?(pid), do: :sys.replace_state(pid, fn _state -> original end)
    end

    test "status surfaces prewarm: warming while the base build is in flight" do
      with_prewarm_enabled()
      with_repo_base_phase(:building)

      output = capture_io(fn -> AgentControlCLI.status() end)
      assert output =~ "PREWARM prewarm: warming phase=building"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "status surfaces a failed base build as a cold-clone fallback" do
      with_prewarm_enabled()
      with_repo_base_phase({:error, :base_build_failed})

      output = capture_io(fn -> AgentControlCLI.status() end)
      assert output =~ "PREWARM prewarm: unavailable"
      assert output =~ "dispatching via cold clone"
    end

    test "status stays silent for a ready base and when prewarm is disabled" do
      # Default fixture config has prewarm disabled.
      disabled_output = capture_io(fn -> AgentControlCLI.status() end)
      refute disabled_output =~ "PREWARM"

      with_prewarm_enabled()
      with_repo_base_phase(:ready)
      ready_output = capture_io(fn -> AgentControlCLI.status() end)
      refute ready_output =~ "PREWARM"
    end
  end

  test "status hides closed cached issues and deactivated runtime entries", %{orchestrator: pid} do
    active = %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"}

    closed_stale_label = %Issue{
      id: "issue-closed-stale-label",
      identifier: "repo#523",
      state: "Closed",
      title: "Closed stale active label",
      labels: ["agent:human-review"]
    }

    closed_unlabeled = %Issue{
      id: "issue-closed-unlabeled",
      identifier: "repo#524",
      state: nil,
      title: "Closed with active label removed"
    }

    deactivated =
      "issue-deactivated"
      |> running_entry("repo#491", :deactivated)
      |> put_in([:issue, Access.key(:title)], "Deactivated")

    closed_running =
      "issue-closed-running"
      |> running_entry("repo#492", :working)
      |> update_in([:issue], &%{&1 | state: "Closed", title: "Closed running"})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => active,
            "issue-closed-stale-label" => closed_stale_label,
            "issue-closed-unlabeled" => closed_unlabeled
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working),
            "issue-deactivated" => deactivated,
            "issue-closed-running" => closed_running
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#44    running Issue repo#44"
    refute output =~ "#491"
    refute output =~ "#492"
    refute output =~ "#523"
    refute output =~ "#524"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "every mutating entrypoint reports an unavailable orchestrator", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      commands = [
        fn -> AgentControlCLI.set_max_agents(2) end,
        fn -> AgentControlCLI.pause(["44"]) end,
        fn -> AgentControlCLI.resume(["44"]) end,
        fn -> AgentControlCLI.reset_budget(["44"]) end,
        fn -> AgentControlCLI.pause_global() end,
        fn -> AgentControlCLI.resume_global() end
      ]

      for command <- commands do
        output = capture_io(command)
        assert output =~ "__AIUR_CONTROL_ERROR__:", output
        assert output =~ "__AIUR_CONTROL_EXIT__:1", output
      end
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "unavailable orchestrator returns clear errors", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      status_output = capture_io(fn -> AgentControlCLI.status() end)

      pause_stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert status_output =~ "__AIUR_CONTROL_ERROR__:aiur: status query failed because the orchestrator is not running"
      assert status_output =~ "__AIUR_CONTROL_EXIT__:1"
      assert pause_stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "status distinguishes a bounded query timeout", %{orchestrator: pid} do
    schedulers = System.schedulers_online()
    load = schedulers * 2.0
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{load} 1.0 1.0 1/1 1"} end)

    on_exit(fn ->
      if previous_loadavg,
        do: Application.put_env(:aiur, :loadavg_source_override, previous_loadavg),
        else: Application.delete_env(:aiur, :loadavg_source_override)
    end)

    :sys.suspend(pid)

    try do
      output = capture_io(fn -> AgentControlCLI.status(status_timeout_ms: 1) end)

      assert output =~
               "LOAD (local fallback diagnostic) #{load} threshold=#{schedulers * 1.5} schedulers=#{schedulers} " <>
                 "(local host sample; over fallback load threshold, PSI governs dispatch when available)"

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 1ms; outcome is unknown"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"

      # #1731: the old wording asserted a cause ("daemon may be
      # scheduler-saturated") that was measurably wrong — the run queue was 1
      # and one process was head-of-line blocked. The replacement must not just
      # drop the false claim, it must print the evidence an operator would
      # otherwise gather by hand. `Process.info/2` reads a suspended process
      # fine, which is exactly why it works when the daemon will not answer.
      assert output =~ "Orchestrator mailbox="

      # The current function is the load-bearing half: it names *where* the
      # process is parked in `:sys.suspend_loop/6`, as #1731 pinpointed
      # `:gen.do_call/4`. Status is unasserted: the query's own message can wake
      # the process to scan its mailbox, so it may read `running` (#3891).
      assert output =~ ~r/status=\w+ in :sys\.suspend_loop\/6/
      assert output =~ "means one process is stuck, not that the host is busy"
    after
      :sys.resume(pid)
    end
  end

  test "status preserves a bounded global-pause query timeout" do
    output =
      capture_io(fn ->
        AgentControlCLI.status(
          status_timeout_ms: 1_000,
          global_pause_status: {:error, :timeout}
        )
      end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 1s; outcome is unknown"
    assert output =~ "__AIUR_CONTROL_EXIT__:124"
  end

  # #1684: `aiur status` exited non-zero printing nothing at all, which reads
  # exactly like a healthy idle fleet. Two independent guarantees below: the
  # render path survives a stalled config store, and anything that still goes
  # wrong says so in one line and carries an exit marker.
  describe "status never exits silently (#1684)" do
    test "renders the table when the config store is stalled", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
      end)

      store = Process.whereis(WorkflowStore)
      Application.put_env(:aiur, :workflow_store_call_timeout_ms, 25)
      :sys.suspend(store)

      on_exit(fn ->
        if Process.alive?(store), do: :sys.resume(store)
        Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
      end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "repo#44"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      refute output =~ "__AIUR_CONTROL_ERROR__"
    end

    test "an unexpected crash is reported in one line with a non-zero exit" do
      Application.put_env(:aiur, :supervision_health_status_fun, fn ->
        raise ArgumentError, "config is unreadable\nsecond line"
      end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query failed (config is unreadable second line)"
      assert output =~ "__AIUR_CONTROL_EXIT__:1"
    end

    test "an unexpected process exit is reported instead of killing the caller" do
      Application.put_env(:aiur, :supervision_health_status_fun, fn -> exit(:boom) end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query failed (process exited: :boom)"
      assert output =~ "__AIUR_CONTROL_EXIT__:1"
    end

    test "an unexpected GenServer timeout keeps the timeout wording and budget" do
      Application.put_env(:aiur, :supervision_health_status_fun, fn ->
        exit({:timeout, {GenServer, :call, [:some_server, :some_request, 8_000]}})
      end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 8s; outcome is unknown"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"
    end
  end

  describe "agents/0" do
    test "prints empty table when no agents are running" do
      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "ISSUE  STATE      RUNTIME  ACTIVITY"
      assert output =~ "(no active agents)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "prints one line per agent with state and current activity", %{orchestrator: pid} do
      active =
        "issue-44"
        |> running_entry("repo#44", :working)
        |> Map.merge(%{
          started_at: DateTime.add(DateTime.utc_now(), -90, :second),
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: "command_execution",
          last_codex_message: "running mix test"
        })

      paused =
        "issue-88"
        |> running_entry("repo#88", :paused)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => active, "issue-88" => paused}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#44"
      assert output =~ "working"
      # Activity prefers the latest event name; runtime renders compactly.
      assert output =~ "command_execution"
      assert output =~ "1m"
      # A paused agent shows its work-state instead of stale activity text.
      assert output =~ "#88"
      assert output =~ "(paused)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "shows startup and retry as distinct from a live turn", %{orchestrator: pid} do
      at = DateTime.utc_now()
      starting = running_entry("issue-2895", "repo#2895", :working) |> Map.put(:session_id, nil)

      retry = %{
        identifier: "repo#2896",
        attempt: 1,
        due_at_ms: System.monotonic_time(:millisecond) + 10_000,
        error: "startup failed: {:port_exit, 23}",
        last_failure_at: at
      }

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{"issue-2895" => starting},
            retry_attempts: %{
              "issue-2896" => retry,
              "issue-2897" => %{retry | identifier: "repo#2897", error: "startup failed: private-key-value"}
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)
      assert output =~ ~r/#2895\s+starting\s/
      assert output =~ "(starting provider; no live turn yet)"
      assert output =~ ~r/#2896\s+retrying\s/
      assert output =~ "startup failed: {:port_exit, 23}"
      assert output =~ DateTime.to_iso8601(at)
      assert output =~ "#2897"
      refute output =~ "private-key-value"
    end

    test "status and agents agree on the human wait for a decision and a rework ticket (#2698)",
         %{orchestrator: pid} do
      # Khala #17 and #52 were both live, working and labelled `rework`. #52 had
      # an open decision; #17 had none. `status` said waiting_for_human for both
      # while `agents` said working for both.
      :ok = SubscriptionStore.attach("repo#52")
      :ok = SubscriptionStore.add_attention("repo#52", "github-credential-missing")
      assert {:ok, %{decision: decision}} = DecisionStore.request(%{"question" => "Provide the missing credential?", "blocking" => true}, ticket: %{identifier: "repo#52"})
      on_exit(fn -> DecisionStore.expire(decision.decision_id, "agent_not_running") end)
      on_exit(fn -> SubscriptionStore.stop("repo#52") end)

      working_rework = fn issue_id, identifier ->
        issue_id
        |> running_entry(identifier, :working)
        |> update_in([:issue], &%{&1 | state: "rework"})
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: "usage/update",
          last_codex_message: nil
        })
      end

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-17" => working_rework.("issue-17", "repo#17"),
              "issue-52" => working_rework.("issue-52", "repo#52")
            }
        }
      end)

      status = capture_io(fn -> AgentControlCLI.status() end)
      agents = capture_io(fn -> AgentControlCLI.agents() end)

      status_line = fn number -> Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "##{number} ")) end
      agents_line = fn number -> Enum.find(String.split(agents, "\n"), &String.starts_with?(&1, "##{number} ")) end

      # Open decision: both surfaces say the agent waits for a human.
      assert status_line.(52) =~ "waiting=waiting_for_human"
      assert agents_line.(52) =~ ~r/^#52\s+waiting\s/
      assert agents_line.(52) =~ "(waiting_for_human: 1 open decision)"

      # No decision: neither surface says waiting_for_human; both say it works.
      assert status_line.(17) =~ "waiting=active"
      refute status =~ ~r/^#17 .*waiting_for_human/m
      assert agents_line.(17) =~ ~r/^#17\s+working\s/
      refute agents_line.(17) =~ "waiting"
    end

    test "preserves paused and deactivated states alongside open attentions", %{orchestrator: pid} do
      for identifier <- ["repo#46", "repo#47"] do
        :ok = SubscriptionStore.attach(identifier)
        :ok = SubscriptionStore.add_attention(identifier, "github-credential-missing")
        assert {:ok, %{decision: decision}} = DecisionStore.request(%{"question" => "Provide the missing credential?", "blocking" => true}, ticket: %{identifier: identifier})
        on_exit(fn -> DecisionStore.expire(decision.decision_id, "agent_not_running") end)
        on_exit(fn -> SubscriptionStore.stop(identifier) end)
      end

      paused =
        "issue-46"
        |> running_entry("repo#46", :paused)
        |> update_in([:issue], &%{&1 | paused: true})
        |> Map.put(:paused_reason, :label_override)

      deactivated = running_entry("issue-47", "repo#47", :deactivated)

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => paused, "issue-47" => deactivated}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ ~r/^#46\s+paused\s+.*\(waiting_for_human: 1 open decision\)/m
      assert output =~ ~r/^#47\s+deactivated\s+.*\(waiting_for_human: 1 open decision\)/m
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "shows label override as the pause reason", %{orchestrator: pid} do
      paused =
        "issue-46"
        |> running_entry("repo#46", :paused)
        |> update_in([:issue], &%{&1 | paused: true})
        |> Map.merge(%{
          paused_reason: :label_override,
          codex_app_server_pid: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => paused}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#46"
      assert output =~ "(paused: label override)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "falls back to last_codex_message, then to a placeholder, and collapses long activity", %{orchestrator: pid} do
      base = fn id, ident -> id |> running_entry(ident, :working) |> Map.merge(%{codex_app_server_pid: nil, last_codex_timestamp: nil}) end

      # event nil -> fall back to message; multi-line + >80 chars -> single line, truncated.
      long = "tool\noutput " <> String.duplicate("x", 120)

      msg_only = base.("issue-1", "repo#1") |> Map.merge(%{last_codex_event: nil, last_codex_message: long})
      idle = base.("issue-2", "repo#2") |> Map.merge(%{last_codex_event: nil, last_codex_message: nil})

      deactivated =
        "issue-3"
        |> running_entry("repo#3", :deactivated)
        |> Map.merge(%{codex_app_server_pid: nil, last_codex_timestamp: nil, last_codex_event: nil, last_codex_message: nil})

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-1" => msg_only, "issue-2" => idle, "issue-3" => deactivated}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      # Activity is collapsed to a single line and ellipsis-truncated.
      assert output =~ "tool output xxx"
      refute output =~ "tool\noutput"
      assert output =~ "…"
      # No-activity and deactivated placeholders render.
      assert output =~ "(no activity yet)"
      assert output =~ "(deactivated)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats structured codex activity maps without crashing", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          "method" => "account/rateLimits/updated",
          "params" => %{
            "rateLimits" => %{
              "credits" => %{"hasCredits" => true, "unlimited" => false},
              "limitId" => "codex",
              "planType" => "business"
            }
          }
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-44"
        |> running_entry("repo#44", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: activity
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#44"
      assert output =~ "rate limits updated"
      refute output =~ ~r/#44\s+working\s+\S+\s+notification/
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats codex activity maps wrapped in payload fields", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          payload: %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "reasoning", "id" => "rs_1234567890abcdef"}}
          }
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-45"
        |> running_entry("repo#45", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: activity
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-45" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#45"
      assert output =~ "item started: reasoning"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats structured codex activity when the event itself is a map", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "reasoning", "content" => [], "summary" => []}}
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-46"
        |> running_entry("repo#46", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: activity,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#46"
      assert output =~ "item started: reasoning"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "inspects unexpected non-string activity without crashing", %{orchestrator: pid} do
      active =
        "issue-47"
        |> running_entry("repo#47", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: {:unexpected, %{payload: make_ref()}},
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-47" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#47"
      assert output =~ "{:unexpected,"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
      Process.unregister(Orchestrator)

      try do
        output = capture_io(fn -> AgentControlCLI.agents() end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: agents query failed because the orchestrator is not running"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      after
        Process.register(pid, Orchestrator)
      end
    end

    test "distinguishes a bounded query timeout", %{orchestrator: pid} do
      :sys.suspend(pid)

      try do
        output = capture_io(fn -> AgentControlCLI.agents(snapshot_timeout_ms: 1) end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: agents query timed out after 1ms; outcome is unknown"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
      after
        :sys.resume(pid)
      end
    end
  end

  describe "alerts/1" do
    test "alerts and watch use the default project ledger" do
      log_root = Aiur.TestSupport.tmp_root!("aiur-default-alert-ledger")
      previous_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "daemon.log"))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if previous_log_file,
          do: Application.put_env(:aiur, :log_file, previous_log_file),
          else: Application.delete_env(:aiur, :log_file)
      end)

      ledger = AlertLedger.path()
      File.mkdir_p!(Path.dirname(ledger))

      File.write!(ledger, "{\"event\":\"alert\",\"topic\":\"ticket.51.agent.paused\",\"reason\":\"operator paused the agent\",\"needs_attention\":true,\"source_ticket_id\":\"51\",\"agent\":\"51\"}\n")

      assert capture_io(fn -> AgentControlCLI.alerts(needs_attention: true) end) =~ "ticket.51.agent.paused"

      assert capture_io(fn -> AgentControlCLI.watch(mode: :full, blocking_asks: []) end) =~
               "#51"
    end

    test "prints persisted alerts as JSON lines with optional attention filtering" do
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-control-alerts")

      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)
      restore_workflow_file_after_test()
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), workspace_root: workspace_root)

      log = Path.join(workspace_root, "repo/51/logs/agent.ndjson")
      File.mkdir_p!(Path.dirname(log))

      File.write!(log, """
      {"event":"alert","timestamp":"2026-06-25T01:00:00Z","name":"ticket.51.agent.phase.work.start","message":"work","reason":"work phase started","needs_attention":false}
      {"event":"alert","timestamp":"2026-06-25T01:01:00Z","name":"ticket.51.agent.paused","message":"paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"51"}
      """)

      ledger = Path.join(workspace_root, "ledger.ndjson")

      File.write!(ledger, """
      {"event":"alert","timestamp":"2026-06-25T01:01:00Z","name":"ticket.51.agent.paused","message":"paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"51"}
      """)

      output = capture_io(fn -> AgentControlCLI.alerts(needs_attention: true, ledger_paths: [ledger]) end)

      assert output =~ "\"topic\":\"ticket.51.agent.paused\""
      assert output =~ "\"reason\":\"operator paused the agent\""
      assert output =~ "\"needs_attention\":true"
      refute output =~ "phase.work.start"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end
  end

  test "build-orders routes ordinary failures through the control marker" do
    output = capture_io(fn -> AgentControlCLI.build_orders(root: "") end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: build-orders accepts one non-empty Build Order root"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "github-cost routes meter failures through the control marker" do
    meter = Process.whereis(Quota)
    assert is_pid(meter)
    assert Process.unregister(Quota)

    output =
      try do
        capture_io(fn -> AgentControlCLI.github_cost() end)
      after
        assert Process.register(meter, Quota)
      end

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: github-cost the GitHub quota meter is not running"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  describe "watch" do
    setup do
      :persistent_term.erase({Aiur.AgentControlCLI, :watch_baseline})

      root = Aiur.TestSupport.tmp_root!("aiur-watch")
      File.mkdir_p!(root)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

      {:ok, watch_root: root}
    end

    test "reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
      Process.unregister(Orchestrator)

      try do
        output = capture_io(fn -> AgentControlCLI.watch() end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: watch query failed because the orchestrator is not running"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      after
        Process.register(pid, Orchestrator)
      end
    end

    test "distinguishes a bounded query timeout", %{orchestrator: pid} do
      :sys.suspend(pid)

      try do
        output = capture_io(fn -> AgentControlCLI.watch(status_timeout_ms: 1) end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: watch query timed out after 1ms; outcome is unknown"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
      after
        :sys.resume(pid)
      end
    end

    test "full board renders state, complexity, and activity per agent", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-44" =>
                watch_entry("issue-44", "repo#44",
                  state: "in-progress",
                  labels: ["agent:in-progress", "complexity:3"],
                  last_codex_message: "running mix test"
                )
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "TICKET  STATE         CX  AGE     DOING"
      assert output =~ ~r/#44\s+in-progress\s+3\s/
      assert output =~ "running mix test"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "watch distinguishes provider startup and retry from a live turn", %{orchestrator: pid, watch_root: root} do
      starting = watch_entry("issue-2895", "repo#2895", state: "in-progress") |> Map.put(:session_id, nil)

      retry = %{
        identifier: "repo#2896",
        attempt: 1,
        due_at_ms: System.monotonic_time(:millisecond) + 10_000,
        error: "startup failed: {:port_exit, 23}"
      }

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-2895" => starting}, retry_attempts: %{"issue-2896" => retry}}
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert output =~ ~r/#2895\s+starting\s/
      assert output =~ "(starting provider; no live turn yet)"
      assert output =~ ~r/#2896\s+retrying\s/
      assert output =~ "startup failed: {:port_exit, 23}"
    end

    test "status and watch surface persisted open blocking operator asks", %{watch_root: root} do
      asks_root = Aiur.TestSupport.tmp_root!("aiur-status-asks")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, asks_root)

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
        Aiur.TestCleanup.rm_rf!(asks_root)
      end)

      restore_workflow_file_after_test()
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

      assert {:ok, ask} =
               Asks.create("owner/repo", %{
                 title: "Enable CI readiness inspection",
                 urgency: "high",
                 blocking: true
               })

      status = capture_io(fn -> AgentControlCLI.status() end)
      assert status =~ "OPERATOR ASKS (blocking)"
      assert status =~ ask["id"]
      assert status =~ "from executor at #{ask["created_at"]}"

      watch = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert watch =~ "ACTIONABLE"
      assert watch =~ "BLOCKING ASK #{ask["id"]}"
      assert watch =~ "Enable CI readiness inspection"

      assert {:ok, _} = Asks.resolve("owner/repo", ask["id"])
      refute capture_io(fn -> AgentControlCLI.status() end) =~ ask["id"]
      refute capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end) =~ ask["id"]
    end

    test "status and watch make an unreadable operator ask store actionable", %{watch_root: root} do
      asks_root = Aiur.TestSupport.tmp_root!("aiur-status-asks")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, asks_root)

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
        Aiur.TestCleanup.rm_rf!(asks_root)
      end)

      restore_workflow_file_after_test()
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
      :ok = RepoBase.ensure_state_tree("owner/repo")

      File.write!(
        RepoBase.asks_path("owner/repo"),
        Jason.encode!(%{
          "id" => "ask_orphan",
          "status" => "done",
          "resolved_at" => "2026-08-08T12:00:00Z",
          "resolved_by" => "executor",
          "note" => nil
        }) <> "\n"
      )

      status = capture_io(fn -> AgentControlCLI.status() end)
      assert status =~ "OPERATOR ASKS (blocking) UNAVAILABLE"
      assert status =~ "could not read durable ask record 1"
      assert status =~ "orphan_done"

      watch = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert watch =~ "ACTIONABLE"
      assert watch =~ "BLOCKING ASKS UNAVAILABLE"
    end

    test "empty board reports no active agents", %{watch_root: root} do
      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "(no active agents)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "full board puts the global pause banner before the table", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true, global_pause: %{paused_at: nil, source: "dashboard"}} end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "GLOBALLY PAUSED (set by dashboard)"
      assert String.starts_with?(output, "GLOBALLY PAUSED")
    end

    test "full board surfaces prewarm: warming while the base warms", %{watch_root: root} do
      with_prewarm_enabled()
      with_repo_base_phase(:building)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "PREWARM prewarm: warming phase=building"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "full board shows paused label override for idle active-state tickets", %{
      orchestrator: pid,
      watch_root: root
    } do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_polled_issues: %{
              "issue-46" => %Issue{
                id: "issue-46",
                identifier: "repo#46",
                state: "todo",
                title: "Paused todo",
                paused: true,
                labels: ["agent:todo", "agent:paused", "complexity:2"]
              }
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ ~r/#46\s+paused\s+2\s/
      assert output =~ "(paused: operator)"
    end

    test "watch shows paused retry causes and reports a reason-only change", %{orchestrator: pid, watch_root: root} do
      retry = %Issue{
        id: "issue-47",
        identifier: "repo#47",
        state: "todo",
        title: "Retrying",
        paused: true,
        labels: ["agent:todo", "agent:paused"]
      }

      due_at_ms = System.monotonic_time(:millisecond) + 240_000

      set_retry = fn error ->
        :sys.replace_state(pid, fn state ->
          %{
            state
            | last_polled_issues: %{retry.id => retry},
              retry_attempts: %{
                retry.id => %{identifier: retry.identifier, attempt: 1, due_at_ms: due_at_ms, error: error}
              }
          }
        end)
      end

      set_retry.("tracker 403")
      first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert first =~ "(paused: operator; transient: tracker 403, retry ~4m)"

      set_retry.("provider unavailable")
      changed = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert changed =~ "#47"
      assert changed =~ "(paused: operator; transient: provider unavailable, retry ~4m)"
    end

    test "changes mode prints a row once, then only when its state shifts", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => watch_entry("issue-44", "repo#44", state: "in-progress")}}
      end)

      first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert first =~ "#44"

      second = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert second =~ "(no changes)"
      refute second =~ "#44"

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => watch_entry("issue-44", "repo#44", state: "rework")}}
      end)

      third = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert third =~ "#44"
      assert third =~ "rework"
    end

    test "changes mode diffs each agent independently", %{orchestrator: pid, watch_root: root} do
      both = fn s45 ->
        %{
          "issue-44" => watch_entry("issue-44", "repo#44", state: "in-progress"),
          "issue-45" => watch_entry("issue-45", "repo#45", state: s45)
        }
      end

      :sys.replace_state(pid, fn state -> %{state | running: both.("in-progress")} end)
      _first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)

      # Only #45 shifts state; #44 holds steady.
      :sys.replace_state(pid, fn state -> %{state | running: both.("rework")} end)
      second = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)

      assert second =~ "#45"
      assert second =~ "rework"
      refute second =~ "#44"
    end

    test "actionable section flags stuck agents and PR-ready tickets", %{orchestrator: pid, watch_root: root} do
      stale_ts = DateTime.add(DateTime.utc_now(), -1_200, :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-44" =>
                watch_entry("issue-44", "repo#44",
                  state: "in-progress",
                  last_codex_timestamp: stale_ts,
                  last_codex_message: "compiling"
                ),
              "issue-45" => watch_entry("issue-45", "repo#45", state: "human-review")
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "ACTIONABLE"
      assert output =~ ~r/#44 stuck/
      assert output =~ ~r/#45 human-review · needs review\/merge/
    end

    test "actionable section surfaces an unanswered operator-decision question", %{watch_root: root} do
      ledger = Path.join(root, "ledger.ndjson")

      File.write!(
        ledger,
        Jason.encode!(%{
          "event" => "alert",
          "name" => "ticket.934.agent.attention.scope-question",
          "topic" => "ticket.934.agent.attention.scope-question",
          "message" => "Executor decision required",
          "reason" => "Executor decision required: Should this facade target change?",
          "severity" => "warning",
          "needs_attention" => true,
          "source_ticket_id" => "934",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, ledger_paths: [ledger]) end)

      assert output =~ "ACTIONABLE"
      assert output =~ "#934"
      assert output =~ "Executor decision required: Should this facade target change?"
    end

    test "resolved operator decisions leave the actionable section", %{watch_root: root} do
      ledger = Path.join(root, "ledger.ndjson")
      initial_at = DateTime.utc_now() |> DateTime.to_iso8601()
      resolved_at = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

      attention = %{
        "event" => "alert",
        "name" => "ticket.934.agent.attention.scope-question",
        "topic" => "ticket.934.agent.attention.scope-question",
        "message" => "Executor decision required",
        "reason" => "Executor decision required: Should this facade target change?",
        "severity" => "warning",
        "needs_attention" => true,
        "source_ticket_id" => "934",
        "timestamp" => initial_at
      }

      resolved = %{
        "event" => "alert",
        "name" => "ticket.934.agent.attention.scope-question.resolved",
        "topic" => "ticket.934.agent.attention.scope-question.resolved",
        "message" => "Executor decision updated",
        "reason" => "Executor decision resolved.",
        "severity" => "info",
        "needs_attention" => false,
        "source_ticket_id" => "934",
        "timestamp" => resolved_at
      }

      File.write!(ledger, Jason.encode!(attention) <> "\n" <> Jason.encode!(resolved) <> "\n")

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, ledger_paths: [ledger], blocking_asks: []) end)

      refute output =~ "ACTIONABLE"
    end

    test "CI-wait remains visible as an automatic gate, not a review-ready ticket", %{
      orchestrator: pid,
      watch_root: root
    } do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-46" => watch_entry("issue-46", "repo#46", state: "ci-wait", work_state: :paused)
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ ~r/#46\s+ci-wait/
      assert output =~ "waiting for CI"
      refute output =~ "#46 ci-wait · needs review/merge"
    end
  end
end
