defmodule Aiur.TicketActivity.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{TicketActivity.Projection, TicketObservation, TrackerIdentity}

  @now ~U[2026-07-15 12:00:00Z]

  test "keeps same-number activity isolated by repository-qualified identity" do
    one = identity("owner-one", "repo-one", "I-42-one", "42")
    two = identity("owner-two", "repo-two", "I-42-two", "42")

    state =
      Projection.new()
      |> Projection.refresh_members([one, two], @now)
      |> apply!(observation(one, :agent_event, "progress", %{percent: 30}, 1))
      |> apply!(observation(two, :agent_event, "progress", %{percent: 70}, 2))

    assert %{progress: %{percent: 30}} = Projection.snapshot(state, one, @now)
    assert %{progress: %{percent: 70}} = Projection.snapshot(state, two, @now)
    assert [_, _] = Projection.snapshots(state, @now).entries
  end

  test "joins by typed identity without copying orchestrator lifecycle fields" do
    ticket = identity()
    status_snapshot = %{identity: ticket, lifecycle: :running, waiting_reason: nil, backend: "codex", model: "gpt"}

    activity_snapshot =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(observation(ticket, :agent_event, "progress", %{percent: 30}, 1))
      |> Projection.snapshot(ticket, @now)

    assert activity_snapshot.identity == status_snapshot.identity

    refute Enum.any?([:lifecycle, :waiting_reason, :backend, :model], fn key ->
             Map.has_key?(activity_snapshot, key)
           end)
  end

  test "orders progress and stage independently without letting late events roll fields back" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(observation(ticket, :agent_event, "progress", %{percent: 40}, 2))
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "phase.work.start",
          %{stage: :work, transition: :start},
          3
        )
      )

    assert {:ignored, :duplicate, state} =
             Projection.apply(
               state,
               observation(ticket, :agent_event, "progress.checkin", %{percent: 10}, 1)
             )

    state =
      apply!(
        state,
        observation(ticket, :agent_alert, "phase.plan.end", %{stage: :plan, transition: :end}, 4)
      )

    assert %{progress: %{percent: 40}, active_stage: :work} =
             Projection.snapshot(state, ticket, @now)

    state =
      apply!(
        state,
        observation(ticket, :agent_alert, "phase.work.end", %{stage: :work, transition: :end}, 5)
      )

    assert %{active_stage: nil} = Projection.snapshot(state, ticket, @now)
  end

  test "advances the stage watermark when a newer transition is semantically rejected" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "phase.work.start",
          %{stage: :work, transition: :start},
          1
        )
      )
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "phase.plan.end",
          %{stage: :plan, transition: :end},
          3
        )
      )

    assert {:ignored, :duplicate, state} =
             Projection.apply(
               state,
               observation(
                 ticket,
                 :agent_alert,
                 "phase.plan.start",
                 %{stage: :plan, transition: :start},
                 2
               )
             )

    assert %{active_stage: :work} = Projection.snapshot(state, ticket, @now)
  end

  test "advances the progress watermark when a newer value is ratcheted away" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(observation(ticket, :agent_event, "progress.phase", %{percent: 80}, 1))
      |> apply!(observation(ticket, :agent_event, "progress.phase", %{percent: 60}, 3))

    assert {:ignored, :duplicate, state} =
             Projection.apply(
               state,
               observation(ticket, :agent_event, "progress.checkin", %{percent: 20}, 2)
             )

    assert %{progress: %{percent: 80}} = Projection.snapshot(state, ticket, @now)
  end

  test "allows a newer attempt to reset progress without treating a new source event as a new attempt" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(
        observation(ticket, :agent_event, "progress", %{percent: 75}, 1, %{
          run_id: "run-1",
          attempt: 1,
          session_id: "session-1",
          source_event_id: "event-1"
        })
      )
      |> apply!(
        observation(ticket, :agent_event, "progress.phase", %{percent: 50}, 2, %{
          run_id: "run-1",
          attempt: 1,
          session_id: "session-1",
          source_event_id: "event-2"
        })
      )

    assert %{progress: %{percent: 75, provenance: %{attempt: 1, source_event_id: "event-1"}}} =
             Projection.snapshot(state, ticket, @now)

    state =
      apply!(
        state,
        observation(ticket, :agent_event, "progress.phase", %{percent: 10}, 3, %{
          run_id: "run-1",
          attempt: 2,
          session_id: "session-2",
          source_event_id: "event-3"
        })
      )

    assert %{progress: %{percent: 10, provenance: %{attempt: 2, source_event_id: "event-3"}}} =
             Projection.snapshot(state, ticket, @now)
  end

  test "retains only canonical opaque progress provenance" do
    ticket = identity()
    token = "ghp_" <> String.duplicate("a", 36)

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(
        observation(ticket, :agent_event, "progress", %{percent: 25}, 1, %{
          run_id: "run-1",
          attempt: 1,
          session_id: "/private/session",
          source_event_id: token
        })
      )

    assert %{progress: %{provenance: %{run_id: "run-1", attempt: 1}}} =
             Projection.snapshot(state, ticket, @now)
  end

  test "ignores unattributed and invalid observations without retaining event content" do
    ticket = identity()
    state = Projection.new() |> Projection.refresh_members([ticket], @now)

    unattributed = %TicketObservation{
      status: :unattributed,
      tracker_identity: nil,
      observed_at: @now
    }

    assert {:ignored, :unattributed, state} = Projection.apply(state, unattributed)

    invalid = %TicketObservation{status: :joinable, tracker_identity: ticket, observed_at: nil}
    assert {:ignored, :invalid, state} = Projection.apply(state, invalid)

    assert %{unattributed: 1, invalid: 1} = Projection.diagnostics(state)
    assert Projection.snapshot(state, ticket, @now) == :not_found
  end

  test "keeps recently removed activity within a bounded retention window and reports eviction" do
    ticket = identity()
    later = DateTime.add(@now, 3, :second)

    state =
      Projection.new(retention_ms: 1_000, max_recent: 1)
      |> apply!(observation(ticket, :agent_event, "progress", %{percent: 20}, 1))

    assert %{retention: %{current: 0, recent: 1, evicted: 0}} = Projection.snapshots(state, @now)
    assert :not_found = state |> Projection.prune(later) |> Projection.snapshot(ticket, later)

    assert %{retention: %{evicted: 1}} =
             Projection.snapshots(Projection.prune(state, later), later)
  end

  test "marks retained activity stale instead of inventing a replacement progress value" do
    ticket = identity()

    state =
      Projection.new(stale_after_ms: 1_000)
      |> Projection.refresh_members([ticket], @now)
      |> apply!(observation(ticket, :agent_event, "progress", %{percent: 40}, 1))

    assert %{status: :stale, progress: %{percent: 40}} =
             Projection.snapshot(state, ticket, DateTime.add(@now, 3, :second))
  end

  test "seeds retained progress so a restart does not re-enter unknown (#1963)" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> Projection.seed_progress([{ticket, retained_progress(40, @now, 1)}], @now)

    assert %{identity: ^ticket, progress: %{status: :known, freshness: :fresh, percent: 40}} =
             Projection.snapshot(state, ticket, @now)
  end

  test "seeded progress renders stale with the real percent after the staleness window" do
    ticket = identity()

    state =
      Projection.new(stale_after_ms: 1_000)
      |> Projection.refresh_members([ticket], @now)
      |> Projection.seed_progress([{ticket, retained_progress(40, @now, 1)}], @now)

    assert %{progress: %{status: :known, freshness: :stale, percent: 40}} =
             Projection.snapshot(state, ticket, DateTime.add(@now, 5, :second))
  end

  test "seeded progress never overwrites a newer live reading" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(observation(ticket, :agent_event, "progress", %{percent: 70}, 2))
      |> Projection.seed_progress([{ticket, retained_progress(40, @now, 1)}], @now)

    assert %{progress: %{status: :known, percent: 70}} = Projection.snapshot(state, ticket, @now)
  end

  test "reports progress and stage freshness from their own observation times" do
    ticket = identity()

    state =
      Projection.new(stale_after_ms: 1_000)
      |> Projection.refresh_members([ticket], @now)
      |> apply!(observation(ticket, :agent_event, "progress", %{percent: 40}, 1))
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "phase.work.start",
          %{stage: :work, transition: :start},
          1
        )
      )
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "alert",
          %{needs_attention: true, severity: "warning"},
          4
        )
      )

    assert %{
             status: :fresh,
             active_stage: :work,
             progress: %{status: :known, freshness: :stale},
             stage: %{status: :known, freshness: :stale, value: :work}
           } = Projection.snapshot(state, ticket, DateTime.add(@now, 5, :second))
  end

  test "normalizes unsupported source metadata before exposing safe evidence" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(
        observation(
          ticket,
          :agent_event,
          "secret token must not escape",
          %{message: "do not retain this raw payload"},
          1
        )
      )

    assert %{latest_evidence: %{source: %{kind: :legacy, name: "unclassified"}, attributes: %{}}} =
             Projection.snapshot(state, ticket, @now)
  end

  test "does not classify a generic alert as an active stage" do
    ticket = identity()

    state =
      Projection.new()
      |> Projection.refresh_members([ticket], @now)
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "phase.work.start",
          %{stage: :work, transition: :start},
          1
        )
      )
      |> apply!(
        observation(
          ticket,
          :agent_alert,
          "alert",
          %{stage: :plan, transition: :end, severity: "warning"},
          2
        )
      )

    assert %{
             active_stage: :work,
             latest_evidence: %{source: %{kind: :agent_alert, name: "alert"}}
           } = Projection.snapshot(state, ticket, @now)
  end

  test "drops malformed timestamp and event metadata from public evidence" do
    ticket = identity()

    unsafe =
      ticket
      |> observation(:agent_event, "progress", %{percent: 40}, 1)
      |> Map.put(:occurred_at, "secret token must not escape")
      |> Map.put(:event_id, %{local_path: "/private/workspace"})

    state = Projection.new() |> Projection.apply(unsafe) |> accepted!()
    snapshot = Projection.snapshot(state, ticket, @now)

    assert %{progress: %{occurred_at: nil, event_id: nil}} = snapshot
    assert %{latest_evidence: %{occurred_at: nil, event_id: nil}} = snapshot
    refute inspect(snapshot) =~ "secret token"
    refute inspect(snapshot) =~ "/private/workspace"
  end

  defp apply!(state, observation) do
    assert {:accepted, state} = Projection.apply(state, observation)
    state
  end

  defp accepted!({:accepted, state}), do: state

  defp retained_progress(percent, observed_at, event_id) do
    %{
      percent: percent,
      source: :phase,
      provenance: %{run_id: "run-1", attempt: 1},
      occurred_at: observed_at,
      observed_at: observed_at,
      event_id: event_id,
      order: {DateTime.to_unix(observed_at, :microsecond), event_id}
    }
  end

  defp observation(identity, kind, name, attributes, seconds, provenance \\ %{}) do
    %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: identity,
      source: %{kind: kind, name: name},
      event_id: seconds + 1,
      provenance: provenance,
      occurred_at: DateTime.add(@now, seconds, :second),
      observed_at: DateTime.add(@now, seconds, :second),
      attributes: attributes
    }
  end

  defp identity(owner \\ "owner", repository \\ "repo", provider_id \\ "I-42", identifier \\ "42") do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: repository,
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end
end
