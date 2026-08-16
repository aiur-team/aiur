defmodule Aiur.Orchestrator.StatusReportTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{State, StatusReport}
  alias Aiur.{ProgressRetention, TrackerIdentity}

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

    assert_receive {:repo_base_timeout, 100}
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

    assert_receive {:repo_base_status_called, 100}
    refute_receive {:repo_base_status_called, _}
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
    assert status.waiting_reason == :waiting_for_human
    assert status.pause_reason == :agent_pause_request
    assert status.blocked_by == []
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
          paused_reason: :agent_pause_request,
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

  test "serves the retained last-known progress when the live projection cannot (#1963)" do
    ticket = identity()

    # `StatusReport` reads `ProgressRetention.all/0`, the supervised default
    # instance the test application runs, so the durable reading is retained
    # into that instance and served through the fallback. The identity is
    # test-unique, so nothing else in the suite reads this key.
    observed_at = DateTime.utc_now()

    assert :ok =
             ProgressRetention.retain(ticket, %{
               percent: 40,
               source: :phase,
               provenance: %{run_id: "run-1", attempt: 1},
               occurred_at: observed_at,
               observed_at: observed_at,
               event_id: 1,
               order: {DateTime.to_unix(observed_at, :microsecond), 1}
             })

    # Synchronize: the retain is an async cast, and `flush` is a call that
    # queues behind it in the same mailbox, so after it returns the mirror the
    # fallback reads is guaranteed to hold the reading.
    assert :ok = ProgressRetention.flush()

    # The live TicketActivity projection is absent (not running in this unit
    # test), so the durable reading is the only source of the percent. The
    # reading is served as the real value with a stale freshness — never a
    # placeholder 0, never unknown for a ticket that has reported.
    issue = %Issue{id: "retained", identifier: "repo#retained", state: "in-progress", title: "Retained", tracker_identity: ticket}

    state = %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
      }
    }

    [row] = StatusReport.snapshot_payload(StatusReport.snapshot_input(state)).running
    assert row.progress_percent == 40
    assert row.progress_freshness == :stale
  end

  test "keeps progress unknown when a ticket has never reported" do
    issue = %Issue{id: "never", identifier: "repo#never", state: "in-progress", title: "Never reported"}

    state = %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
      }
    }

    [row] = StatusReport.snapshot_payload(StatusReport.snapshot_input(state)).running
    assert row.progress_percent == nil
    assert row.progress_freshness == :unknown
  end

  test "a retained reading wins over a live entry that has no progress of its own (#1963)" do
    ticket = identity("I-1963-edge")
    observed_at = DateTime.utc_now()

    assert :ok =
             ProgressRetention.retain(ticket, %{
               percent: 60,
               source: :phase,
               provenance: %{run_id: "run-1", attempt: 1},
               occurred_at: observed_at,
               observed_at: observed_at,
               event_id: 1,
               order: {DateTime.to_unix(observed_at, :microsecond), 1}
             })

    assert :ok = ProgressRetention.flush()

    # A stage-only event creates a live projection entry for the ticket that
    # carries no progress reading. Without the per-identity merge refinement
    # that live `:unknown` would blank the retained 60%.
    send(Aiur.TicketActivity, {:event, %{ticket_observation: stage_only(ticket)}})

    issue = %Issue{id: "edge", identifier: "repo#edge", state: "in-progress", title: "Edge", tracker_identity: ticket}

    state = %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
      }
    }

    [row] = StatusReport.snapshot_payload(StatusReport.snapshot_input(state)).running
    assert row.progress_percent == 60
    assert row.progress_freshness == :stale
  end

  defp identity(provider_id \\ "I-42") do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: provider_id,
      identifier: "42",
      reason: nil
    }
  end

  defp stage_only(ticket) do
    now = DateTime.utc_now()

    %Aiur.TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: ticket,
      source: %{kind: :agent_alert, name: "phase.work.start"},
      event_id: 9,
      provenance: %{run_id: "run-1", attempt: 1},
      occurred_at: now,
      observed_at: now,
      attributes: %{stage: :work, transition: :start}
    }
  end
end
