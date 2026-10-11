defmodule Aiur.Orchestrator.StatusReportProgressTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.ProgressRetention
  alias Aiur.Projections.UnitsRow
  alias Aiur.TrackerIdentity

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

  test "running snapshot carries the telemetry attempt ID" do
    issue = %Issue{id: "attempt-snapshot", identifier: "repo#attempt-snapshot", state: "in-progress", title: "Attempt"}

    state = %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          telemetry_attempt_id: "attempt-snapshot-current",
          control: %{status: :working}
        }
      }
    }

    assert [%{telemetry_attempt_id: "attempt-snapshot-current"}] =
             StatusReport.snapshot_payload(StatusReport.snapshot_input(state)).running
  end

  test "Units keeps a missing running turn count unknown but preserves an observed zero" do
    ticket = identity("turn-count-source")

    issue = %Issue{
      id: "turn-count-source",
      identifier: "repo#turn-count-source",
      state: "in-progress",
      title: "Turn count source",
      tracker_identity: ticket
    }

    entry = %{
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.utc_now(),
      control: %{status: :working}
    }

    for {running_entry, expected_count, expected_source} <- [
          {entry, nil, :unknown},
          {Map.put(entry, :turn_count, 0), 0, :status_report}
        ] do
      [status_row] =
        %State{running: %{issue.id => running_entry}}
        |> StatusReport.snapshot_input()
        |> StatusReport.snapshot_payload()
        |> Map.fetch!(:running)

      snapshot =
        UnitsRow.snapshot(%{
          membership: %{members: [%{identity: ticket, lifecycle: :running}]},
          status: %{running: [status_row], retrying: [], idle: []}
        })

      assert {:ok, row} = UnitsRow.lookup(snapshot, ticket)
      assert row.turn_count == expected_count
      assert row.field_sources.turn_count == expected_source
    end
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
