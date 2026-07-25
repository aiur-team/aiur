defmodule Aiur.UsageAggregate.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.UsageAggregate.{Key, Projection}
  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1, claude_envelope: 1, record: 3, money: 1]

  test "folds ordered deltas into exact per-dimension cells and advances the source position" do
    projection =
      Projection.new()
      |> Projection.apply_record(record(1, envelope(%{}), %{tokens: %{input: 10, output: 4}}))
      |> Projection.apply_record(record(2, envelope(%{}), %{tokens: %{input: 5}, cost: money("2.50")}))

    assert projection.source_position == 2
    assert projection.generation == 2
    dims = Key.dims(envelope(%{}))
    assert projection.cells[{dims, {:token, :input}}] == 15
    assert projection.cells[{dims, {:token, :output}}] == 4
    assert Decimal.equal?(projection.cells[{dims, {:money, :provider_reported_estimate, "USD"}}], Decimal.new("2.50"))
  end

  test "ignores any delta at or before the persisted source position without inflating totals" do
    base = Projection.apply_record(Projection.new(), record(1, envelope(%{}), %{tokens: %{input: 10}}))

    # Duplicate delivery of the same position and a stale lower position are both no-ops.
    replayed =
      base
      |> Projection.apply_record(record(1, envelope(%{}), %{tokens: %{input: 10}}))
      |> Projection.apply_record(record(0, envelope(%{}), %{tokens: %{input: 99}}))

    dims = Key.dims(envelope(%{}))
    assert replayed.cells[{dims, {:token, :input}}] == 10
    assert replayed.source_position == 1
    assert replayed.generation == 1
  end

  test "keeps identical dimensions under two relationship revisions in separate cells" do
    revision_a = envelope(%{relationship_revision: "codex-app-server-2026-07"})
    revision_b = envelope(%{relationship_revision: "codex-app-server-2026-08"})

    projection =
      Projection.new()
      |> Projection.apply_record(record(1, revision_a, %{tokens: %{input: 10}}))
      |> Projection.apply_record(record(2, revision_b, %{tokens: %{input: 10}}))

    assert Projection.cell_count(projection) == 2
    assert projection.cells[{Key.dims(revision_a), {:token, :input}}] == 10
    assert projection.cells[{Key.dims(revision_b), {:token, :input}}] == 10
  end

  test "separates providers, models, and account generations into distinct partitions" do
    projection =
      Projection.new()
      |> Projection.apply_record(record(1, envelope(%{}), %{tokens: %{input: 10}}))
      |> Projection.apply_record(record(2, claude_envelope(%{}), %{tokens: %{input: 10}}))

    assert Projection.cell_count(projection) == 2
    assert Key.dims(envelope(%{})).provider == :codex
    assert Key.dims(claude_envelope(%{})).provider == :claude
  end

  test "drops zero and absent token or cost contributions" do
    projection =
      Projection.apply_record(
        Projection.new(),
        record(1, envelope(%{}), %{tokens: %{input: 0, output: nil}, cost: nil})
      )

    assert Projection.cell_count(projection) == 0
    assert projection.source_position == 1
  end

  test "accumulates explicit partial coverage and unknown-attribution reasons" do
    partial = envelope(%{update_kind: :partial, coverage_reasons: [:partial_update]})

    projection =
      Projection.new()
      |> Projection.apply_record(record(1, envelope(%{}), %{tokens: %{input: 10}}))
      |> Projection.apply_record(record(2, partial, %{tokens: %{input: 4}}))

    assert projection.coverage.folded_records == 2
    assert projection.coverage.partial_records == 1
    assert MapSet.member?(projection.coverage.reasons, :partial_update)
  end
end
