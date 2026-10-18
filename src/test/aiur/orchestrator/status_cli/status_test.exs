Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliStatusTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.ExecutorWakeInbox

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

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
end
