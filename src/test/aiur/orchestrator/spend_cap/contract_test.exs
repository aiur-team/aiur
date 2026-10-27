defmodule Aiur.Orchestrator.SpendCap.ContractTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.SpendCap.{Evaluation, Record}
  alias Aiur.TestSupport.GroupedScopes, as: GS

  @fixtures Path.expand("../../../../../packages/aiur-contracts/fixtures", __DIR__)
  @configured_at ~U[2026-10-24 20:00:00Z]
  @reached_at ~U[2026-10-24 20:01:00Z]
  @revision "multi-provider-standard-global-2026-08-16"

  test "live read serialization equals the versioned package fixture" do
    record = Record.new!(GS.identity("aiur-team", "aiur", 5693), "1.25", @configured_at)
    {:active, record} = Evaluation.refresh(record, usage("0.50", 3, 8, 2), @configured_at)

    assert Record.public(record) == fixture("ticket-spend-cap.v1.json")
  end

  test "live reached-event serialization equals the versioned package fixture" do
    record = Record.new!(GS.identity("aiur-team", "aiur", 5693), "1.25", @configured_at)
    {:reached, record} = Evaluation.refresh(record, usage("1.25", 4, 9, 3), @reached_at)

    assert Record.event_payload(record) == fixture("ticket-spend-cap-reached.v1.json")
  end

  defp usage(amount, aggregate_generation, source_position, known) do
    %{
      state: :known,
      authority: %{
        schema_version: 1,
        aggregate_generation: aggregate_generation,
        source_position: source_position,
        source_generation: 2,
        price_table_revision: @revision
      },
      api_equivalent_estimate: %{
        rollup: %{"USD" => Decimal.new(amount)},
        coverage: %{status: :known, known: known, unknown: 0, reasons: []}
      }
    }
  end

  defp fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
