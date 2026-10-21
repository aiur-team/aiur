Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliCapacityLimitsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

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
      %{state | last_polled_issues: %{"issue-queued" => queued_issue()}, max_concurrent_agents: 10, effective_concurrent_agents: 2}
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
end
