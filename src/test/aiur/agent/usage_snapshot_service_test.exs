defmodule Aiur.Agent.UsageSnapshotServiceTest do
  use ExUnit.Case

  alias Aiur.Agent.UsageSnapshotService
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.Headless.Codex.ThreadUsage
  alias Aiur.UsageAggregate.Projection
  alias Aiur.UsageLedger.CounterPolicy
  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1]

  test "accepts a repository-qualified ticket identity for ticket scope" do
    ticket = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "I_kwDO2881",
      identifier: "2881",
      reason: nil
    }

    assert {:error, :no_usage_data} = UsageSnapshotService.current("2881", ticket: ticket)
  end

  test "thread cumulative snapshots become accepted deltas and aggregate to the latest total once" do
    policy = CounterPolicy.new()
    first = thread_snapshot(1, 100, 25, 20)
    second = thread_snapshot(2, 150, 40, 30)

    {:ok, first_result} = CounterPolicy.apply(policy, first)
    {:ok, second_result} = CounterPolicy.apply(first_result.state, second)

    records = [record(1, first, first_result.delta), record(2, second, second_result.delta)]
    projection = Projection.apply_records(Projection.new(), records)
    metrics = UsageSnapshotService.aggregate_metrics_from_cells(projection.cells)

    assert metrics == %{
             input: 150,
             output: 30,
             cached_input: 40,
             uncached_input: 110,
             cached_proportion: 40 / 150
           }
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

  defp thread_snapshot(sequence, input, cached_input, output) do
    envelope(%{
      idempotency_key: "snapshot-#{sequence}",
      source_event_id: "snapshot-#{sequence}",
      source_sequence: sequence,
      relationship_revision: ThreadUsage.relationship_revision(),
      source: "codex.app_server.thread_token_usage",
      measurement_kind: :absolute,
      counter_scope: :thread,
      tokens: %{input: input, cached_input: cached_input, output: output}
    })
  end

  defp record(position, envelope, delta) do
    %{position: position, generation: position, envelope: envelope, delta: delta}
  end
end
