Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliReasonsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{Config, DispatchBudgetStore, Issue}
  alias Aiur.GitHub.CiReadiness
  alias Aiur.Orchestrator.State

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

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

    assert output =~ "#44    agent:paused-agent"
    assert output =~ "waiting=paused"
    assert output =~ "pause_reason=agent_pause_request"
    assert output =~ "#99    agent:blocked"
    assert output =~ "waiting=waiting_for_dependency"
    assert output =~ "blocked_by=repo#12"
  end

  test "status prints a persisted CI reason label exactly", %{orchestrator: pid} do
    issue = %Issue{
      id: "issue-ci",
      identifier: "repo#ci",
      state: "ci-wait",
      labels: ["agent:ci-wait", "agent:ci-red"]
    }

    paused =
      running_entry("issue-ci", "repo#ci", :paused)
      |> Map.put(:issue, issue)

    :sys.replace_state(pid, fn state -> %{state | running: %{"issue-ci" => paused}} end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "repo#ci"
    assert output =~ "agent:ci-wait,agent:ci-red"
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
    assert output =~ "#18    agent:todo,agent:retrying,agent:paused Retrying (operator; transient: tracker 403, retry ~4m)"
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
             "#19    agent:todo,agent:paused Operator pause (operator)"
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
end
