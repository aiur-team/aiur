defmodule Aiur.Agent.UsageSnapshotServiceTest do
  use ExUnit.Case

  alias Aiur.Agent.UsageSnapshotService
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.Headless.Codex.ThreadUsage
  alias Aiur.UsageAggregate.Projection
  alias Aiur.UsageLedger.CounterPolicy
  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1, record: 3]

  test "current reports cumulative thread snapshots as one attempt total" do
    ticket = ticket_identity()
    attempt_id = "attempt-current"
    {projection, records} = current_projection(ticket, attempt_id)

    assert {:ok, snapshot} =
             UsageSnapshotService.current("2881",
               ticket: ticket,
               attempt_id: attempt_id,
               cells_snapshot_fun: fn -> %{cells: projection.cells, metadata: %{source_position: 2}} end,
               ledger_scan_fun: fn _opts -> {:ok, records} end
             )

    assert snapshot.cumulative_metrics == %{
             input: 150,
             output: 30,
             cached_input: 40,
             uncached_input: 110,
             cached_proportion: 40 / 150
           }

    assert snapshot.scope == :attempt
    assert snapshot.observed_at == ~U[2026-07-15 00:00:02Z]
  end

  test "current assembles a qualified ticket scope without raising" do
    ticket = ticket_identity()
    {projection, records} = current_projection(ticket, "attempt-ticket")

    assert {:ok, snapshot} =
             UsageSnapshotService.current("2881",
               ticket: ticket,
               cells_snapshot_fun: fn -> %{cells: projection.cells, metadata: %{source_position: 2}} end,
               ledger_scan_fun: fn _opts -> {:ok, records} end
             )

    assert snapshot.scope == :ticket
    assert snapshot.scope_id == inspect(TrackerIdentity.github_key(ticket))
  end

  test "does not combine cells from different relationship revisions" do
    cells = %{
      {%{relationship_revision: "revision-a"}, {:token, :input}} => 100,
      {%{relationship_revision: "revision-b"}, {:token, :input}} => 20
    }

    assert %{input: {:unknown, :multiple_relationship_revisions}} =
             UsageSnapshotService.aggregate_metrics_from_cells(cells)
  end

  test "unknown dimensions stay unknown while known provider totals remain usable" do
    cells = %{
      {%{relationship_revision: ThreadUsage.relationship_revision(), model: "one"}, {:token, :input}} => 100
    }

    assert %{input: 100, cached_input: {:unknown, :not_reported}, output: {:unknown, :not_reported}, uncached_input: {:unknown, :missing_cached_input}} =
             UsageSnapshotService.aggregate_metrics_from_cells(cells)
  end

  test "a partially reported cache dimension is not presented as a complete sum" do
    cells = %{
      {%{relationship_revision: ThreadUsage.relationship_revision()}, {:token, :input}} => 100,
      {%{relationship_revision: ThreadUsage.relationship_revision()}, {:token, :cached_input}} => 20
    }

    assert %{input: 100, cached_input: {:unknown, :incomplete_measurement}, uncached_input: {:unknown, :missing_cached_input}} =
             UsageSnapshotService.aggregate_metrics_from_cells(cells, %{input: true, output: false, cached_input: false})
  end

  test "a verified zero stays zero while an absent unverified dimension stays unknown" do
    cells = %{{%{relationship_revision: ThreadUsage.relationship_revision()}, {:token, :output}} => 12}

    metrics = UsageSnapshotService.aggregate_metrics_from_cells(cells, %{input: true, output: true, cached_input: false})

    assert metrics.input == 0
    assert metrics.output == 12
    assert metrics.cached_input == {:unknown, :incomplete_measurement}
  end

  defp ticket_identity do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "I_kwDO2881",
      identifier: "2881",
      reason: nil
    }
  end

  defp current_projection(ticket, attempt_id) do
    first = thread_snapshot(1, 100, 25, 20, ticket, attempt_id)
    second = thread_snapshot(2, 150, 40, 30, ticket, attempt_id)

    {:ok, first_result} = CounterPolicy.apply(CounterPolicy.new(), first)
    {:ok, second_result} = CounterPolicy.apply(first_result.state, second)

    records = [
      record(1, first, delta_overrides(first, first_result.delta)),
      record(2, second, delta_overrides(second, second_result.delta))
    ]

    {Projection.apply_records(Projection.new(), records), records}
  end

  defp delta_overrides(envelope, delta) do
    %{
      tokens: delta.tokens,
      source_version: envelope.source_version,
      relationship_revision: envelope.relationship_revision,
      coverage_reasons: envelope.coverage_reasons
    }
  end

  defp thread_snapshot(sequence, input, cached_input, output, ticket, attempt_id) do
    envelope(%{
      idempotency_key: "snapshot-#{sequence}",
      source_event_id: "snapshot-#{sequence}",
      source_sequence: sequence,
      relationship_revision: ThreadUsage.relationship_revision(),
      source: "codex.app_server.thread_token_usage",
      source_version: "codex-thread-usage-2026-07",
      measurement_kind: :absolute,
      counter_scope: :thread,
      tokens: %{input: input, cached_input: cached_input, output: output},
      attribution: %{
        run_id: "run-2881",
        tracker_identity: ticket,
        attempt_id: attempt_id,
        session_id: "session-2881",
        thread_id: "thread-2881",
        turn_id: nil,
        request_id: nil
      }
    })
  end
end
