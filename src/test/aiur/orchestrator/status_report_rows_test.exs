defmodule Aiur.Orchestrator.StatusReportRowsTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.CapacityBinding
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReason
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Store

  test "snapshot projection retains last dispatch poll age and never-polled state" do
    now_ms = System.monotonic_time(:millisecond)
    state = %State{last_dispatch_poll_at_ms: now_ms - 481_000}
    snapshot = StatusReport.snapshot_payload(StatusReport.snapshot_input(state))
    assert snapshot.polling.last_dispatch_poll_age_ms >= 481_000
    assert snapshot.polling.last_dispatch_poll_age_ms < 482_000
    never = StatusReport.snapshot_payload(StatusReport.snapshot_input(%State{}))
    assert never.polling.last_dispatch_poll_age_ms == nil
  end

  test "retained snapshots age a dispatch poll until it becomes stale" do
    orchestrator = self()
    on_exit(fn -> SnapshotStore.forget(orchestrator) end)
    now_ms = System.monotonic_time(:millisecond)
    state = %State{last_dispatch_poll_at_ms: now_ms - 479_000, poll_interval_ms: 240_000}
    snapshot = StatusReport.snapshot_payload(StatusReport.snapshot_input(state))
    :ok = SnapshotStore.publish(orchestrator, snapshot)
    {:current, first, _metadata} = SnapshotStore.read(orchestrator, 50)
    assert CapacityBinding.dispatch_poll_status(first.polling).freshness == :fresh
    Process.sleep(1_100)
    {:current, retained, metadata} = SnapshotStore.read(orchestrator, 50)
    assert retained.polling.last_dispatch_poll_age_ms > 480_000
    assert metadata.age_ms >= 1_100
    assert CapacityBinding.dispatch_poll_status(retained.polling).freshness == :stale
  end

  test "calculates the remaining poll interval" do
    assert StatusReport.next_poll_in_ms(nil, 10) == nil
    assert StatusReport.next_poll_in_ms(20, 10) == 10
    assert StatusReport.next_poll_in_ms(5, 10) == 0
  end

  test "renders a retry without a current tracker snapshot" do
    due_at_ms = System.monotonic_time(:millisecond) + 240_000

    statuses =
      StatusReport.agent_statuses(%State{
        retry_attempts: %{
          "missing" => %{identifier: "repo#20", attempt: 1, due_at_ms: due_at_ms, error: "provider unavailable"}
        }
      })

    assert [%{identifier: "repo#20", state: :paused, title: nil, reason: {:transient, _, _}}] = statuses
  end

  test "startup and retry rows expose no live turn and retain failure time" do
    issue = %Issue{id: "2895", identifier: "2895", state: "in-progress", title: "Startup"}
    now = DateTime.utc_now()
    entry = %{identifier: issue.identifier, issue: issue, started_at: now, session_id: nil, control: %{status: :working}}

    [starting] = StatusReport.agent_statuses(%State{running: %{issue.id => entry}})
    assert starting.work_state == :starting
    assert starting.session_id == nil

    retry = %{
      identifier: issue.identifier,
      attempt: 1,
      due_at_ms: System.monotonic_time(:millisecond) + 10_000,
      error: "startup failed: {:port_exit, 23}",
      last_failure_at: now
    }

    [retrying] = StatusReport.agent_statuses(%State{retry_attempts: %{issue.id => retry}})
    assert retrying.work_state == :retrying
    assert retrying.last_failure_at == now
    assert {:transient, "startup failed: {:port_exit, 23}", due_in_ms} = retrying.reason
    assert due_in_ms > 0
    assert retrying.session_id == nil
  end

  test "gives tracker pause precedence while retaining retry metadata" do
    due_at_ms = System.monotonic_time(:millisecond) + 240_000
    paused = %{id: "paused-retry", identifier: "repo#21", state: "todo", paused: true}

    assert [status] =
             StatusReport.agent_statuses(%State{
               last_polled_issues: %{paused.id => paused},
               retry_attempts: %{
                 paused.id => %{identifier: paused.identifier, attempt: 1, due_at_ms: due_at_ms, error: "tracker 403"}
               }
             })

    assert status.tracker_paused
    assert {:paused, :label_override, {:transient, "tracker 403", _}} = status.reason
    assert {:transient, "tracker 403", _} = status.retry_reason
  end

  test "takes a bounded prewarm snapshot and handles an exited base server" do
    assert :building =
             StatusReport.prewarm_phase(fn timeout ->
               send(self(), {:repo_base_timeout, timeout})
               {:building, "/tmp/base"}
             end)

    assert_receive {:repo_base_timeout, 100}, 1000
    assert :unavailable = StatusReport.prewarm_phase(fn _timeout -> exit(:noproc) end)
  end

  test "uses one prewarm snapshot for every idle row" do
    issues =
      for id <- ["one", "two"], into: %{} do
        {id, %{id: id, identifier: "repo##{id}", state: "todo", paused: false}}
      end

    statuses =
      StatusReport.agent_statuses(%State{last_polled_issues: issues}, fn timeout ->
        send(self(), {:repo_base_status_called, timeout})
        {:building, "/tmp/base"}
      end)

    assert_receive {:repo_base_status_called, 100}, 1000
    refute_receive {:repo_base_status_called, _}, 100
    assert Enum.all?(statuses, &(&1.reason == :prewarm_blocked))
  end

  test "status rows expose waiting and pause reasons consistently" do
    issue = %Issue{id: "paused", identifier: "repo#paused", state: "in-progress", title: "Needs input"}

    entry = %{
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.add(DateTime.utc_now(), -900, :second),
      paused_reason: :agent_pause_request,
      control: %{status: :paused}
    }

    [status] = StatusReport.agent_statuses(%State{running: %{issue.id => entry}})

    assert status.state == :paused
    assert status.waiting_reason == :paused
    assert status.pause_reason == :agent_pause_request
    assert status.blocked_by == []
  end

  test "distinguishes an orphaned tracker claim from a live in-progress runtime" do
    orphan = %Issue{id: "orphan", identifier: "repo#orphan", state: "in-progress", title: "Orphaned claim"}
    live = %Issue{id: "live", identifier: "repo#live", state: "in-progress", title: "Live claim"}

    state = %State{
      last_polled_issues: %{orphan.id => orphan, live.id => live},
      running: %{
        live.id => %{
          identifier: live.identifier,
          issue: live,
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
      }
    }

    statuses = StatusReport.agent_statuses(state, fn _ -> {:unavailable, nil} end)
    orphan_status = Enum.find(statuses, &(&1.issue_id == orphan.id))
    live_status = Enum.find(statuses, &(&1.issue_id == live.id))

    assert orphan_status.state == :idle
    assert orphan_status.waiting_reason == :orphaned_claim
    assert orphan_status.reason == :orphaned_claim
    assert live_status.state == :running
    assert live_status.waiting_reason == :active

    [snapshot_orphan] = StatusReport.snapshot_payload(StatusReport.snapshot_input(state)).idle
    assert snapshot_orphan.waiting_reason == :orphaned_claim
  end

  test "a ticket parked in workspace-ownership recovery is not reported as an orphaned claim" do
    recovering = %Issue{
      id: "recovering",
      identifier: "repo#208",
      state: "in-progress",
      title: "Provider-limit recovery"
    }

    envelope = %{issue_id: recovering.id, identifier: recovering.identifier, owner: :none}

    waiting =
      put_in(
        %State{last_polled_issues: %{recovering.id => recovering}, running: %{}}.dispatch_recovery.workspace_ownership.waits,
        %{recovering.identifier => envelope}
      )

    [waiting_status] = StatusReport.agent_statuses(waiting, fn _ -> {:unavailable, nil} end)

    assert waiting_status.state == :idle
    assert waiting_status.waiting_reason == :workspace_ownership_waiting
    assert waiting_status.reason == :workspace_ownership_waiting

    ready =
      put_in(
        %State{last_polled_issues: %{recovering.id => recovering}, running: %{}}.dispatch_recovery.workspace_ownership.ready,
        %{recovering.id => envelope}
      )

    [ready_status] = StatusReport.agent_statuses(ready, fn _ -> {:unavailable, nil} end)

    assert ready_status.waiting_reason == :workspace_ownership_waiting
    assert ready_status.reason == :workspace_ownership_waiting

    [snapshot_row] = StatusReport.snapshot_payload(StatusReport.snapshot_input(ready)).idle
    assert snapshot_row.waiting_reason == :workspace_ownership_waiting
  end

  test "a retained unknown provider reports its exact generation and missing exit proof" do
    identifier = "repo#unknown-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "todo", title: "Retained unknown provider"}
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = Ownership.claim(identifier)
        :ok = Ownership.expect_provider(lease)
        send(parent, {:unknown_provider_lease, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:unknown_provider_lease, lease}, 2_000

    on_exit(fn ->
      Process.exit(lease.guardian, :kill)
      _ = Store.delete(identifier)
    end)

    Process.exit(owner, :kill)
    assert await_reaping(identifier, 100)

    envelope = %{issue_id: issue.id, identifier: identifier, owner: :none}

    state =
      put_in(
        %State{last_polled_issues: %{issue.id => issue}}.dispatch_recovery.workspace_ownership.waits,
        %{identifier => envelope}
      )

    assert [%{waiting_reason: :workspace_ownership_waiting, reason: {:workspace_ownership_waiting, ^identifier, generation, :not_recorded}} = status] =
             StatusReport.agent_statuses(state, fn _ -> {:unavailable, nil} end)

    assert generation == lease.generation
    assert StatusReason.render(status.reason) =~ "workspace ownership held (generation #{generation})"
    assert StatusReason.render(status.reason) =~ "unknown provider; exit proof not recorded"
  end

  test "after the startup pass an idle in-progress claim reads as stale, never awaiting-dispatch" do
    orphan = %Issue{id: "stale-orphan", identifier: "repo#stale", state: "in-progress", title: "Stale claim"}

    state = %State{
      startup_claim_reconciliation_complete?: true,
      last_polled_issues: %{orphan.id => orphan},
      running: %{}
    }

    [status] = StatusReport.agent_statuses(state, fn _ -> {:unavailable, nil} end)

    assert status.state == :idle
    assert status.waiting_reason == :stale_claim
    assert status.reason == :stale_claim
    refute status.waiting_reason == :orphaned_claim
  end

  test "idle dependency rows expose the blocker and dependency waiting reason" do
    blocker = %{id: "blocker", identifier: "repo#blocker", state: "in-progress"}
    issue = %Issue{id: "waiting", identifier: "repo#waiting", state: "todo", blocked_by: [blocker]}

    [status] = StatusReport.agent_statuses(%State{last_polled_issues: %{issue.id => issue}}, fn _ -> {:unavailable, nil} end)

    assert status.waiting_reason == :waiting_for_dependency
    assert status.blocked_by == [blocker]

    state = %State{last_polled_issues: %{issue.id => issue}}
    snapshot_input = StatusReport.snapshot_input(state)
    [snapshot_status] = StatusReport.snapshot_payload(snapshot_input).idle

    assert snapshot_status.waiting_reason == status.waiting_reason
    assert snapshot_status.blocked_by == status.blocked_by
  end

  test "idle rows expose a blocking Command dispatch decline in live and snapshot status" do
    issue = %Issue{id: "blocked-command", identifier: "repo#blocked-command", state: "todo"}

    state = %State{
      last_polled_issues: %{issue.id => issue},
      dispatch_declines: %{issue.id => :blocked_on_decision}
    }

    [status] = StatusReport.agent_statuses(state, fn _ -> {:unavailable, nil} end)
    assert status.dispatch_decline_reason == :blocked_on_decision

    snapshot_input = StatusReport.snapshot_input(state)
    [snapshot_status] = StatusReport.snapshot_payload(snapshot_input).idle
    assert snapshot_status.dispatch_decline_reason == :blocked_on_decision
  end

  test "snapshot input preserves auto-resume evidence for parity" do
    issue = %Issue{id: "transient", identifier: "repo#transient", state: "todo"}

    state = %State{
      last_polled_issues: %{issue.id => issue},
      auto_resume: %{issue.id => %{attempt: 1, scheduled_at_ms: 0}}
    }

    snapshot_input = StatusReport.snapshot_input(state)
    assert snapshot_input.auto_resume == state.auto_resume

    [status] = StatusReport.agent_statuses(state, fn _ -> {:unavailable, nil} end)
    [snapshot_status] = StatusReport.snapshot_payload(snapshot_input).idle

    assert status.waiting_reason == :paused_transient
    assert snapshot_status.waiting_reason == status.waiting_reason
  end

  test "a released claim is projected into the snapshot and wins the waiting reason (#1475)" do
    issue = %Issue{id: "released", identifier: "repo#1475", state: "todo"}
    release = %{cause: :rate_limit, details: %{}, released_at_ms: System.monotonic_time(:millisecond)}

    state = %State{
      last_polled_issues: %{issue.id => issue},
      released_claims: %{issue.id => release}
    }

    snapshot_input = StatusReport.snapshot_input(state)
    assert snapshot_input.released_claims == state.released_claims

    [status] = StatusReport.agent_statuses(state, fn _ -> {:unavailable, nil} end)

    assert status.claim_released?
    assert status.claim_release_cause == :rate_limit
    assert status.waiting_reason == :claim_released
    assert {:claim_released, :rate_limit, nil} = status.reason

    [snapshot_status] = StatusReport.snapshot_payload(snapshot_input).idle
    assert snapshot_status.claim_released?
    assert snapshot_status.claim_release_cause == :rate_limit
    assert snapshot_status.waiting_reason == :claim_released
  end

  test "human-wait alert threshold is episode-based and inclusive" do
    now = ~U[2026-08-11 12:00:00Z]

    refute StatusReport.waiting_for_human_alert_due?(DateTime.add(now, -599, :second), now)
    assert StatusReport.waiting_for_human_alert_due?(DateTime.add(now, -600, :second), now)
  end

  test "syncs an overdue wait episode without a status read" do
    issue = %Issue{id: "waiting", identifier: "repo#waiting", state: "in-progress"}
    now = ~U[2026-08-11 12:00:00Z]

    state = %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.add(now, -600, :second),
          paused_reason: :input_required,
          control: %{status: :paused}
        }
      },
      waiting_for_human_episodes: %{
        issue.identifier => %{since: DateTime.add(now, -600, :second), alerted?: false}
      }
    }

    identifier = issue.identifier

    assert %{waiting_for_human_episodes: %{^identifier => %{alerted?: true}}} =
             StatusReport.sync_waiting_for_human_episodes(state, now)
  end

  defp await_reaping(_identifier, 0), do: false

  defp await_reaping(identifier, remaining) do
    if match?({:ok, %{phase: :reaping}}, Ownership.current(identifier)) do
      true
    else
      Process.sleep(10)
      await_reaping(identifier, remaining - 1)
    end
  end
end
